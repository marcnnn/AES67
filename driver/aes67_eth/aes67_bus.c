// SPDX-License-Identifier: GPL-2.0
/*
 * Bus-agnostic Wishbone access layer + /dev/aes67ctl control char device.
 *
 * The actual transport lives in the backend (aes67_spi.c: LiteX spibone wire
 * protocol over SPI; aes67_pci.c: memory-mapped BAR0 window). Everything above
 * this layer (netdev, PHC, ctl device, ALSA) only sees Wishbone byte addresses
 * and 32-bit words.
 */
#include <linux/fs.h>
#include <linux/module.h>
#include <linux/uaccess.h>

#include "aes67_eth.h"
#include "aes67_uapi.h"

int aes67_wb_read_locked(struct aes67_priv *p, u32 addr, u32 *val)
{
	lockdep_assert_held(&p->bus_lock);
	return p->ops->read(p, addr, val);
}

int aes67_wb_write_locked(struct aes67_priv *p, u32 addr, u32 val)
{
	lockdep_assert_held(&p->bus_lock);
	return p->ops->write(p, addr, val);
}

/* Burst: `n` bytes as `n` consecutive 32-bit words starting at word address
 * `addr` (eth_buf packs one byte per word, in the low byte). Backends without
 * a native burst fall back to one word per byte. */
int aes67_wb_write_burst_locked(struct aes67_priv *p, u32 addr,
				const u8 *bytes, unsigned int n)
{
	unsigned int i;
	int ret;

	lockdep_assert_held(&p->bus_lock);
	if (p->ops->write_burst)
		return p->ops->write_burst(p, addr, bytes, n);

	for (i = 0; i < n; i++) {
		ret = p->ops->write(p, addr + 4 * i, bytes[i]);
		if (ret)
			return ret;
	}
	return 0;
}

int aes67_wb_read_burst_locked(struct aes67_priv *p, u32 addr,
			       u8 *bytes, unsigned int n)
{
	unsigned int i;
	u32 word;
	int ret;

	lockdep_assert_held(&p->bus_lock);
	if (p->ops->read_burst)
		return p->ops->read_burst(p, addr, bytes, n);

	for (i = 0; i < n; i++) {
		ret = p->ops->read(p, addr + 4 * i, &word);
		if (ret)
			return ret;
		bytes[i] = word & 0xff;
	}
	return 0;
}

/*
 * Packed-layout burst write: store `n` payload bytes as ceil(n/4) consecutive
 * words, four bytes per word in little-endian lanes (frame byte 4i+k in word
 * i bits [8k+7:8k]). A final partial word is zero-padded — eth_buf_tx_len
 * bounds the frame, the pad is never transmitted.
 */
int aes67_wb_write_burst_packed_locked(struct aes67_priv *p, u32 addr,
				       const u8 *bytes, unsigned int n)
{
	lockdep_assert_held(&p->bus_lock);

	if (!use_burst) {
		while (n) {
			unsigned int take = min(n, 4u);
			u32 word = 0;
			unsigned int k;
			int ret;

			for (k = 0; k < take; k++)
				word |= (u32)bytes[k] << (8 * k);
			ret = aes67_wb_write_locked(p, addr, word);
			if (ret)
				return ret;
			addr  += 4;
			bytes += take;
			n     -= take;
		}
		return 0;
	}

	while (n) {
		unsigned int words = min(DIV_ROUND_UP(n, 4u),
					 AES67_PACKED_WR_CHUNK);
		unsigned int take_total = min(n, words * 4);
		const u8 *src = bytes;
		unsigned int rem = take_total;
		u8 *tx = p->spi_tx;
		u8 *rx = p->spi_rx;
		unsigned int len, w, i;
		int ret;

		tx[0] = CMD_BURST_WRITE;
		put_unaligned_be32(addr, &tx[1]);
		put_unaligned_be16((u16)words, &tx[5]);
		for (w = 0; w < words; w++) {
			unsigned int take = min(rem, 4u);
			u32 word = 0;
			unsigned int k;

			for (k = 0; k < take; k++)
				word |= (u32)src[k] << (8 * k);
			put_unaligned_be32(word, &tx[7 + 4 * w]);
			src += take;
			rem -= take;
		}
		len = 7 + 4 * words;
		memset(&tx[len], 0xff, BURST_WR_SLACK);
		len += BURST_WR_SLACK;

		ret = aes67_spi_xfer(p, tx, rx, len);
		if (ret)
			return ret;

		/* Confirm the device clocked out its 0x00 completion ack. */
		for (i = 7 + 4 * words; i < len; i++) {
			if (rx[i] == CMD_WRITE)   /* 0x00 ack */
				break;
			if (rx[i] != 0xff)
				return -EIO;
		}
		if (i == len)
			return -ETIMEDOUT;

		addr  += 4 * words;
		bytes += take_total;
		n     -= take_total;
	}
	return 0;
}

/*
 * Packed-layout burst read: fetch `n` payload bytes from ceil(n/4)
 * consecutive words (four bytes per word, little-endian lanes). Never writes
 * more than `n` bytes into the caller's buffer.
 */
int aes67_wb_read_burst_packed_locked(struct aes67_priv *p, u32 addr,
				      u8 *bytes, unsigned int n)
{
	lockdep_assert_held(&p->bus_lock);

	if (!use_burst) {
		while (n) {
			unsigned int take = min(n, 4u);
			unsigned int k;
			u32 word;
			int ret;

			ret = aes67_wb_read_locked(p, addr, &word);
			if (ret)
				return ret;
			for (k = 0; k < take; k++)
				bytes[k] = (u8)(word >> (8 * k));
			addr  += 4;
			bytes += take;
			n     -= take;
		}
		return 0;
	}

	while (n) {
		unsigned int words = min(DIV_ROUND_UP(n, 4u),
					 AES67_PACKED_RD_CHUNK);
		unsigned int take_total = min(n, words * 4);
		unsigned int rem = take_total;
		u8 *tx = p->spi_tx;
		u8 *rx = p->spi_rx;
		unsigned int len, i, w;
		int ret;

		tx[0] = CMD_BURST_READ;
		put_unaligned_be32(addr, &tx[1]);
		put_unaligned_be16((u16)words, &tx[5]);
		len = 7 + 7 * words + BURST_RD_SLACK;
		memset(&tx[7], 0xff, len - 7);

		ret = aes67_spi_xfer(p, tx, rx, len);
		if (ret)
			return ret;

		i = 7;
		for (w = 0; w < words; w++) {
			unsigned int take = min(rem, 4u);
			unsigned int k;
			u32 word;

			/* Skip the 0xff the device drives during read latency. */
			while (i < len && rx[i] == 0xff)
				i++;
			if (i + 5 > len || rx[i] != CMD_READ)  /* 0x01 + 4 data */
				return -ETIMEDOUT;
			word = get_unaligned_be32(&rx[i + 1]);
			for (k = 0; k < take; k++)
				bytes[k] = (u8)(word >> (8 * k));
			bytes += take;
			rem   -= take;
			i     += 5;
		}

		addr += 4 * words;
		n    -= take_total;
	}
	return 0;
}

int aes67_wb_read(struct aes67_priv *p, u32 addr, u32 *val)
{
	int ret;

	mutex_lock(&p->bus_lock);
	ret = aes67_wb_read_locked(p, addr, val);
	mutex_unlock(&p->bus_lock);
	return ret;
}

int aes67_wb_write(struct aes67_priv *p, u32 addr, u32 val)
{
	int ret;

	mutex_lock(&p->bus_lock);
	ret = aes67_wb_write_locked(p, addr, val);
	mutex_unlock(&p->bus_lock);
	return ret;
}

/* --- /dev/aes67ctl: raw peek/poke for userspace (aes67d / aes67cfg) -------- */

static struct aes67_priv *ctl_to_priv(struct file *f)
{
	struct miscdevice *m = f->private_data;

	return container_of(m, struct aes67_priv, ctl_dev);
}

static long aes67_ctl_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct aes67_priv *p = ctl_to_priv(f);
	struct aes67_wb_xfer x;
	void __user *uarg = (void __user *)arg;
	int ret;

	switch (cmd) {
	case AES67_IOC_PEEK:
		if (copy_from_user(&x, uarg, sizeof(x)))
			return -EFAULT;
		ret = aes67_wb_read(p, x.addr, &x.val);
		if (ret)
			return ret;
		if (copy_to_user(uarg, &x, sizeof(x)))
			return -EFAULT;
		return 0;
	case AES67_IOC_POKE:
		if (copy_from_user(&x, uarg, sizeof(x)))
			return -EFAULT;
		return aes67_wb_write(p, x.addr, x.val);
	default:
		return -ENOTTY;
	}
}

static const struct file_operations aes67_ctl_fops = {
	.owner          = THIS_MODULE,
	.unlocked_ioctl = aes67_ctl_ioctl,
	.compat_ioctl   = compat_ptr_ioctl,
};

int aes67_ctl_register(struct aes67_priv *p)
{
	p->ctl_dev.minor = MISC_DYNAMIC_MINOR;
	p->ctl_dev.name  = "aes67ctl";
	p->ctl_dev.fops  = &aes67_ctl_fops;
	return misc_register(&p->ctl_dev);
}

void aes67_ctl_unregister(struct aes67_priv *p)
{
	misc_deregister(&p->ctl_dev);
}
