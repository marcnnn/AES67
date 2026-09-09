// SPDX-License-Identifier: GPL-2.0
/*
 * spibone backend: LiteX SPI -> Wishbone bridge (Raspberry Pi + external FPGA).
 *
 * Implements the LiteX spibone 4-wire wire protocol (see
 * config_tool/crates/transport/src/spi.rs, which this mirrors byte-for-byte):
 *
 *   write: [0x00][addr BE][value BE]; device holds MISO high (0xff) until the
 *          Wishbone write completes, then returns a 0x00 ack byte.
 *   read:  [0x01][addr BE]; device holds MISO high until data is ready, then a
 *          0x01 sync byte followed by the 32-bit value (big-endian).
 *
 * spibone drops the low two address bits in gateware, so the full byte address
 * goes on the wire. Each transaction is one full-duplex SPI transfer with
 * trailing 0xff padding clocked out to capture the variable-latency response.
 *
 * For the frame hot paths we also use the repo-local spibone fork's burst
 * commands: [0x02|0x03][addr BE][count BE16][...] streams many
 * auto-incrementing words per SPI transfer instead of one round-trip per word.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/unaligned.h>

#include "aes67_eth.h"

#define CMD_WRITE 0x00
#define CMD_READ  0x01
#define CMD_BURST_WRITE 0x02
#define CMD_BURST_READ  0x03
/* Padding bytes clocked out to capture the device response; spibone answers
 * within a couple of bytes at any sane clock, so this is generous. */
#define RESPONSE_SLACK 24
#define BURST_WR_SLACK 8
#define BURST_RD_SLACK 16

/* Per-transfer SPI clock override (Hz). 0 = use the DT spi-max-frequency.
 * spibone tops out at sys_clk/4 (~18.75 MHz at 75 MHz); keep below that. The
 * default 1 MHz matches the userspace tool and is safe for bring-up. */
static unsigned int spi_hz = 1000000;
module_param(spi_hz, uint, 0644);
MODULE_PARM_DESC(spi_hz, "SPI clock in Hz (0 = DT default). Must stay below spibone's sys_clk/4.");

/* Use the spibone burst commands (0x02/0x03) on the frame hot paths. Requires a
 * burst-capable bitstream (litex_soc/spi_bone.py with_burst). Set to 0 to fall
 * back to single-word transfers — necessary when the loaded FPGA gateware
 * predates burst support (every burst would otherwise time out). */
static bool use_burst = true;
module_param(use_burst, bool, 0644);
MODULE_PARM_DESC(use_burst, "Use spibone burst transfers (0 = single-word fallback for pre-burst gateware)");

static int aes67_spi_xfer(struct aes67_priv *p, const u8 *tx, u8 *rx, size_t len)
{
	struct spi_transfer t = {
		.tx_buf    = tx,
		.rx_buf    = rx,
		.len       = len,
		.speed_hz  = spi_hz,   /* 0 → controller falls back to the DT max */
	};
	struct spi_message m;

	spi_message_init(&m);
	spi_message_add_tail(&t, &m);
	return spi_sync(p->spi, &m);
}

static int aes67_spi_read(struct aes67_priv *p, u32 addr, u32 *val)
{
	u8 tx[5 + RESPONSE_SLACK];
	u8 rx[5 + RESPONSE_SLACK];
	int ret, i;

	tx[0] = CMD_READ;
	put_unaligned_be32(addr, &tx[1]);
	memset(&tx[5], 0xff, RESPONSE_SLACK);

	ret = aes67_spi_xfer(p, tx, rx, sizeof(tx));
	if (ret)
		return ret;

	/* Scan past the address echo for the sync byte, skipping the 0xff the
	 * device drives while the read is in flight. */
	for (i = 5; i + 4 < (int)sizeof(rx); i++) {
		if (rx[i] == CMD_READ) {
			*val = get_unaligned_be32(&rx[i + 1]);
			return 0;
		}
		if (rx[i] != 0xff)
			return -EIO;
	}
	return -ETIMEDOUT;
}

static int aes67_spi_write(struct aes67_priv *p, u32 addr, u32 val)
{
	u8 tx[9 + RESPONSE_SLACK];
	u8 rx[9 + RESPONSE_SLACK];
	int ret, i;

	tx[0] = CMD_WRITE;
	put_unaligned_be32(addr, &tx[1]);
	put_unaligned_be32(val, &tx[5]);
	memset(&tx[9], 0xff, RESPONSE_SLACK);

	ret = aes67_spi_xfer(p, tx, rx, sizeof(tx));
	if (ret)
		return ret;

	for (i = 9; i < (int)sizeof(rx); i++) {
		if (rx[i] == CMD_WRITE)
			return 0;
		if (rx[i] != 0xff)
			return -EIO;
	}
	return -ETIMEDOUT;
}

static int aes67_spi_write_burst(struct aes67_priv *p, u32 addr,
				 const u8 *bytes, unsigned int n)
{
	/* Fallback for gateware without burst support: one word per byte. */
	if (!use_burst) {
		unsigned int i;
		int ret;

		for (i = 0; i < n; i++) {
			ret = aes67_spi_write(p, addr + 4 * i, bytes[i]);
			if (ret)
				return ret;
		}
		return 0;
	}

	while (n) {
		unsigned int chunk = min(n, AES67_BURST_WR_CHUNK);
		u8 *tx = p->spi_tx;
		u8 *rx = p->spi_rx;
		unsigned int len, i;
		int ret;

		tx[0] = CMD_BURST_WRITE;
		put_unaligned_be32(addr, &tx[1]);
		put_unaligned_be16((u16)chunk, &tx[5]);
		for (i = 0; i < chunk; i++) {
			tx[7 + 4 * i + 0] = 0;
			tx[7 + 4 * i + 1] = 0;
			tx[7 + 4 * i + 2] = 0;
			tx[7 + 4 * i + 3] = bytes[i];
		}
		len = 7 + 4 * chunk;
		memset(&tx[len], 0xff, BURST_WR_SLACK);
		len += BURST_WR_SLACK;

		ret = aes67_spi_xfer(p, tx, rx, len);
		if (ret)
			return ret;

		/* Confirm the device clocked out its 0x00 completion ack. */
		for (i = 7 + 4 * chunk; i < len; i++) {
			if (rx[i] == CMD_WRITE)   /* 0x00 ack */
				break;
			if (rx[i] != 0xff)
				return -EIO;
		}
		if (i == len)
			return -ETIMEDOUT;

		addr  += 4 * chunk;
		bytes += chunk;
		n     -= chunk;
	}
	return 0;
}

static int aes67_spi_read_burst(struct aes67_priv *p, u32 addr,
				u8 *bytes, unsigned int n)
{
	if (!use_burst) {
		unsigned int i;
		int ret;
		u32 word;

		for (i = 0; i < n; i++) {
			ret = aes67_spi_read(p, addr + 4 * i, &word);
			if (ret)
				return ret;
			bytes[i] = word & 0xff;
		}
		return 0;
	}

	while (n) {
		unsigned int chunk = min(n, AES67_BURST_RD_CHUNK);
		u8 *tx = p->spi_tx;
		u8 *rx = p->spi_rx;
		unsigned int len, i, w;
		int ret;

		tx[0] = CMD_BURST_READ;
		put_unaligned_be32(addr, &tx[1]);
		put_unaligned_be16((u16)chunk, &tx[5]);
		/* 7-byte header echo + up to 7 bytes/word ([pad][sync][4 data]) +
		 * slack; clock 0xff across the whole response window. */
		len = 7 + 7 * chunk + BURST_RD_SLACK;
		memset(&tx[7], 0xff, len - 7);

		ret = aes67_spi_xfer(p, tx, rx, len);
		if (ret)
			return ret;

		i = 7;
		for (w = 0; w < chunk; w++) {
			/* Skip the 0xff the device drives during read latency. */
			while (i < len && rx[i] == 0xff)
				i++;
			if (i + 5 > len || rx[i] != CMD_READ)  /* 0x01 + 4 data */
				return -ETIMEDOUT;
			bytes[w] = rx[i + 4];   /* low byte of the BE32 word */
			i += 5;
		}

		addr  += 4 * chunk;
		bytes += chunk;
		n     -= chunk;
	}
	return 0;
}

static const struct aes67_bus_ops aes67_spi_bus_ops = {
	.name        = "spibone",
	.read        = aes67_spi_read,
	.write       = aes67_spi_write,
	.read_burst  = aes67_spi_read_burst,
	.write_burst = aes67_spi_write_burst,
};

/* --- probe / remove ------------------------------------------------------- */

static int aes67_spi_probe(struct spi_device *spi)
{
	struct aes67_priv *p;
	int ret;

	p = aes67_alloc(&spi->dev);
	if (!p)
		return -ENOMEM;
	p->spi = spi;
	p->ops = &aes67_spi_bus_ops;
	p->irq = spi->irq;

	/* DMA-safe scratch for SPI burst transfers (auto-freed on driver detach). */
	p->spi_tx = devm_kmalloc(&spi->dev, AES67_BURST_BUF, GFP_KERNEL);
	p->spi_rx = devm_kmalloc(&spi->dev, AES67_BURST_BUF, GFP_KERNEL);
	if (!p->spi_tx || !p->spi_rx) {
		ret = -ENOMEM;
		goto err_free;
	}

	spi_set_drvdata(spi, p);
	ret = aes67_core_probe(p);
	if (ret)
		goto err_free;
	return 0;

err_free:
	aes67_free(p);
	return ret;
}

static void aes67_spi_remove(struct spi_device *spi)
{
	struct aes67_priv *p = spi_get_drvdata(spi);

	aes67_core_remove(p);
	aes67_free(p);
}

static const struct of_device_id aes67_of_match[] = {
	{ .compatible = "aes67,spibone" },
	{ }
};
MODULE_DEVICE_TABLE(of, aes67_of_match);

/* The SPI core derives the modalias from the DT compatible by stripping the
 * vendor prefix ("aes67,spibone" -> "spibone"), so the id_table entry must be
 * named "spibone" to match (otherwise: "has no spi_device_id" warning). */
static const struct spi_device_id aes67_spi_ids[] = {
	{ "spibone", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, aes67_spi_ids);

static struct spi_driver aes67_spi_driver = {
	.driver = {
		.name = "aes67_eth",
		.of_match_table = aes67_of_match,
	},
	.id_table = aes67_spi_ids,
	.probe = aes67_spi_probe,
	.remove = aes67_spi_remove,
};

int aes67_spi_register(void)
{
	return spi_register_driver(&aes67_spi_driver);
}

void aes67_spi_unregister(void)
{
	spi_unregister_driver(&aes67_spi_driver);
}
