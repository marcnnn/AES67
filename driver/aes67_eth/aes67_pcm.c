// SPDX-License-Identifier: GPL-2.0
/*
 * ALSA PCM on the PCIe audio DMA engine (FPGA/pcie/pcie_audio_dma.vhd).
 *
 * Classic bus-mastering sound card model: ALSA allocates the ring buffer in
 * coherent DMA memory, we program its bus address / size / period into the
 * engine, and the FPGA streams frames at the AES67 media clock rate, raising
 * an interrupt at every period boundary. The engine reports the position as a
 * byte offset (playback: consumed, lagging by its small FIFO; capture: written
 * and completed), which maps 1:1 onto the ALSA hw pointer.
 *
 * Format is fixed by the gateware: interleaved S32_LE (24 valid bits, MSB
 * aligned), 48 kHz, one channel per AES67 parallel-register channel.
 * Playback channel n = AES67 TX channel n, capture channel n = AES67 RX
 * channel n; which channels form which RTP stream is configured through the
 * usual control plane (aes67cfg).
 */
#include <linux/io.h>
#include <linux/module.h>
#include <linux/spinlock.h>
#include <sound/core.h>
#include <sound/initval.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>

#include "aes67_eth.h"
#include "aes67_pcie_regs.h"

enum { AES67_PB = 0, AES67_CAP = 1 };

struct aes67_pcm {
	struct aes67_priv *p;
	struct snd_card   *card;
	struct snd_pcm    *pcm;
	spinlock_t         lock;          /* CTRL register read-modify-write */
	struct snd_pcm_substream *ss[2];
	bool               running[2];
	unsigned int       channels[2];
	unsigned int       beat_bytes;
	unsigned int       fifo_depth;    /* beats */
};

static inline void __iomem *dma_reg(struct aes67_priv *p, u32 off)
{
	return p->bar + AES67_PCIE_DMA_OFFSET + off;
}

static const struct snd_pcm_hardware aes67_pcm_hw = {
	.info = SNDRV_PCM_INFO_MMAP | SNDRV_PCM_INFO_MMAP_VALID |
		SNDRV_PCM_INFO_INTERLEAVED | SNDRV_PCM_INFO_BLOCK_TRANSFER |
		SNDRV_PCM_INFO_BATCH,
	.formats          = SNDRV_PCM_FMTBIT_S32_LE,
	.rates            = SNDRV_PCM_RATE_48000,
	.rate_min         = 48000,
	.rate_max         = 48000,
	.channels_min     = 1,
	.channels_max     = 64,
	.buffer_bytes_max = 1 << 20,
	.period_bytes_min = 256,
	.period_bytes_max = 1 << 18,
	.periods_min      = 2,
	.periods_max      = 1024,
};

static int aes67_pcm_open(struct snd_pcm_substream *ss)
{
	struct aes67_pcm *a = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	int dir = ss->stream == SNDRV_PCM_STREAM_PLAYBACK ? AES67_PB : AES67_CAP;
	unsigned int frame_bytes = a->channels[dir] * 4;
	int ret;

	rt->hw = aes67_pcm_hw;
	rt->hw.channels_min = a->channels[dir];
	rt->hw.channels_max = a->channels[dir];
	/* One period must hold at least a few frames and cover the engine's
	 * prefetch FIFO, so the reported pointer never lags a whole period. */
	rt->hw.period_bytes_min = max_t(unsigned int, 256,
					roundup(a->fifo_depth * a->beat_bytes, frame_bytes));

	ret = snd_pcm_hw_constraint_integer(rt, SNDRV_PCM_HW_PARAM_PERIODS);
	if (ret < 0)
		return ret;
	/* Bursts are beat-sized; frames already are whole beats (gateware
	 * asserts CHANNELS*32 % AXI width == 0), keep periods frame-aligned. */
	ret = snd_pcm_hw_constraint_step(rt, 0, SNDRV_PCM_HW_PARAM_PERIOD_BYTES, frame_bytes);
	if (ret < 0)
		return ret;

	a->ss[dir] = ss;
	return 0;
}

static int aes67_pcm_close(struct snd_pcm_substream *ss)
{
	struct aes67_pcm *a = snd_pcm_substream_chip(ss);
	int dir = ss->stream == SNDRV_PCM_STREAM_PLAYBACK ? AES67_PB : AES67_CAP;

	a->ss[dir] = NULL;
	return 0;
}

static void aes67_pcm_set_run(struct aes67_pcm *a, int dir, bool on)
{
	struct aes67_priv *p = a->p;
	u32 bit = dir == AES67_PB ? AES67_DMA_CTRL_PB_RUN : AES67_DMA_CTRL_CAP_RUN;
	unsigned long flags;
	u32 ctrl;

	spin_lock_irqsave(&a->lock, flags);
	ctrl = ioread32(dma_reg(p, AES67_DMA_CTRL));
	ctrl = on ? (ctrl | bit) : (ctrl & ~bit);
	iowrite32(ctrl, dma_reg(p, AES67_DMA_CTRL));
	a->running[dir] = on;
	spin_unlock_irqrestore(&a->lock, flags);
}

static int aes67_pcm_prepare(struct snd_pcm_substream *ss)
{
	struct aes67_pcm *a = snd_pcm_substream_chip(ss);
	struct aes67_priv *p = a->p;
	struct snd_pcm_runtime *rt = ss->runtime;
	int dir = ss->stream == SNDRV_PCM_STREAM_PLAYBACK ? AES67_PB : AES67_CAP;
	u32 base = dir == AES67_PB ? AES67_DMA_PB_ADDR_LO : AES67_DMA_CAP_ADDR_LO;
	u64 addr = rt->dma_addr;
	u32 ring = snd_pcm_lib_buffer_bytes(ss);
	u32 period = snd_pcm_lib_period_bytes(ss);
	u32 burst, caps_burst;

	if (addr & 0xfff) {
		dev_err(p->dev, "DMA buffer not 4 KiB aligned\n");
		return -EINVAL;
	}

	/* A stopped direction restarts from ring offset 0 with a flushed FIFO. */
	aes67_pcm_set_run(a, dir, false);
	iowrite32(lower_32_bits(addr), dma_reg(p, base + 0x0));
	iowrite32(upper_32_bits(addr), dma_reg(p, base + 0x4));
	iowrite32(ring,   dma_reg(p, base + 0x8));
	iowrite32(period, dma_reg(p, base + 0xc));

	/* ~256-byte bursts unless the FIFO is smaller; the engine clamps too. */
	burst = clamp_t(u32, 256 / a->beat_bytes, 1, a->fifo_depth / 2);
	caps_burst = ioread32(dma_reg(p, AES67_DMA_BURST));
	if (dir == AES67_PB)
		caps_burst = (caps_burst & 0xff00) | burst;
	else
		caps_burst = (caps_burst & 0x00ff) | (burst << 8);
	iowrite32(caps_burst, dma_reg(p, AES67_DMA_BURST));

	/* clear sticky error flags */
	iowrite32(AES67_DMA_STATUS_PB_UNDERRUN | AES67_DMA_STATUS_CAP_OVERRUN,
		  dma_reg(p, AES67_DMA_STATUS));
	return 0;
}

static int aes67_pcm_trigger(struct snd_pcm_substream *ss, int cmd)
{
	struct aes67_pcm *a = snd_pcm_substream_chip(ss);
	int dir = ss->stream == SNDRV_PCM_STREAM_PLAYBACK ? AES67_PB : AES67_CAP;

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
	case SNDRV_PCM_TRIGGER_PAUSE_RELEASE:
		aes67_pcm_set_run(a, dir, true);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
	case SNDRV_PCM_TRIGGER_PAUSE_PUSH:
		aes67_pcm_set_run(a, dir, false);
		return 0;
	default:
		return -EINVAL;
	}
}

static snd_pcm_uframes_t aes67_pcm_pointer(struct snd_pcm_substream *ss)
{
	struct aes67_pcm *a = snd_pcm_substream_chip(ss);
	int dir = ss->stream == SNDRV_PCM_STREAM_PLAYBACK ? AES67_PB : AES67_CAP;
	u32 off = ioread32(dma_reg(a->p, dir == AES67_PB ? AES67_DMA_PB_HW_PTR
							 : AES67_DMA_CAP_HW_PTR));

	if (off >= snd_pcm_lib_buffer_bytes(ss))
		off = 0;
	return bytes_to_frames(ss->runtime, off);
}

static const struct snd_pcm_ops aes67_pcm_ops = {
	.open    = aes67_pcm_open,
	.close   = aes67_pcm_close,
	.prepare = aes67_pcm_prepare,
	.trigger = aes67_pcm_trigger,
	.pointer = aes67_pcm_pointer,
};

/* Hard-IRQ context. */
void aes67_pcm_irq(struct aes67_priv *p, u32 status)
{
	struct aes67_pcm *a = p->pcm;

	if (!a)
		return;
	if ((status & AES67_IRQ_PB_PERIOD) && a->running[AES67_PB] && a->ss[AES67_PB])
		snd_pcm_period_elapsed(a->ss[AES67_PB]);
	if ((status & AES67_IRQ_CAP_PERIOD) && a->running[AES67_CAP] && a->ss[AES67_CAP])
		snd_pcm_period_elapsed(a->ss[AES67_CAP]);
	if ((status & AES67_IRQ_PB_UNDERRUN) && a->running[AES67_PB] && a->ss[AES67_PB]) {
		dev_warn_ratelimited(p->dev, "playback FIFO underrun\n");
		snd_pcm_stop_xrun(a->ss[AES67_PB]);
	}
	if ((status & AES67_IRQ_CAP_OVERRUN) && a->running[AES67_CAP] && a->ss[AES67_CAP]) {
		dev_warn_ratelimited(p->dev, "capture FIFO overrun\n");
		snd_pcm_stop_xrun(a->ss[AES67_CAP]);
	}
}

int aes67_pcm_register(struct aes67_priv *p)
{
	struct aes67_pcm *a;
	u32 caps;
	int ret;

	caps = ioread32(dma_reg(p, AES67_DMA_CAPS));
	if (!AES67_DMA_CAPS_PB_CH(caps) && !AES67_DMA_CAPS_CAP_CH(caps)) {
		dev_info(p->dev, "gateware has no audio DMA channels, no ALSA card\n");
		return 0;
	}

	a = kzalloc(sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;
	a->p = p;
	spin_lock_init(&a->lock);
	a->channels[AES67_PB]  = AES67_DMA_CAPS_PB_CH(caps);
	a->channels[AES67_CAP] = AES67_DMA_CAPS_CAP_CH(caps);
	a->beat_bytes = AES67_DMA_CAPS_BEAT_BYTES(caps);
	a->fifo_depth = 1u << AES67_DMA_CAPS_FIFO_BITS(caps);

	ret = snd_card_new(p->dev, SNDRV_DEFAULT_IDX1, "AES67", THIS_MODULE, 0, &a->card);
	if (ret < 0)
		goto err_free;
	strscpy(a->card->driver, "AES67", sizeof(a->card->driver));
	strscpy(a->card->shortname, "AES67 PCIe", sizeof(a->card->shortname));
	snprintf(a->card->longname, sizeof(a->card->longname),
		 "AES67 PCIe sound card (%u out / %u in) at %s",
		 a->channels[AES67_PB], a->channels[AES67_CAP], dev_name(p->dev));

	ret = snd_pcm_new(a->card, "AES67 PCM", 0,
			  a->channels[AES67_PB] ? 1 : 0,
			  a->channels[AES67_CAP] ? 1 : 0, &a->pcm);
	if (ret < 0)
		goto err_card;
	a->pcm->private_data = a;
	strscpy(a->pcm->name, "AES67 network audio", sizeof(a->pcm->name));
	if (a->channels[AES67_PB])
		snd_pcm_set_ops(a->pcm, SNDRV_PCM_STREAM_PLAYBACK, &aes67_pcm_ops);
	if (a->channels[AES67_CAP])
		snd_pcm_set_ops(a->pcm, SNDRV_PCM_STREAM_CAPTURE, &aes67_pcm_ops);
	snd_pcm_set_managed_buffer_all(a->pcm, SNDRV_DMA_TYPE_DEV, p->dev,
				       256 * 1024, 1 << 20);

	ret = snd_card_register(a->card);
	if (ret < 0)
		goto err_card;

	p->pcm = a;
	dev_info(p->dev, "ALSA card: %u playback / %u capture channels, S32_LE 48 kHz\n",
		 a->channels[AES67_PB], a->channels[AES67_CAP]);
	return 0;

err_card:
	snd_card_free(a->card);
err_free:
	kfree(a);
	return ret;
}

void aes67_pcm_unregister(struct aes67_priv *p)
{
	struct aes67_pcm *a = p->pcm;

	if (!a)
		return;
	p->pcm = NULL;
	iowrite32(0, dma_reg(p, AES67_DMA_CTRL));
	snd_card_free(a->card);
	kfree(a);
}
