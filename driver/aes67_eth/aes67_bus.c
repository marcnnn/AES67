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
