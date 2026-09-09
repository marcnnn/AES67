// SPDX-License-Identifier: GPL-2.0
/*
 * PCIe backend: the FPGA is a PCIe card (FPGA/boards/xilinx/alibaba_ku3p).
 *
 * BAR0 carries three regions (aes67_pcie_regs.h): the LiteX aes67_bridge
 * Wishbone window (plain MMIO, one 32-bit access per Wishbone cycle), the
 * audio DMA engine and the board/interrupt control block. A single MSI (or
 * INTx) vector signals eth_buf RX-ready, DMA period boundaries and DMA
 * errors; the hard handler dispatches the PCM events straight to ALSA and
 * wakes a thread for the netdev datapath (which takes the sleeping bus_lock).
 */
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>

#include "aes67_eth.h"
#include "aes67_pcie_regs.h"

struct aes67_pci {
	struct aes67_priv *p;
	struct pci_dev    *pdev;
	int                irq;
	u32                irq_enable;   /* mirror of AES67_CTL_IRQ_ENABLE */
};

/* --- Wishbone window over MMIO -------------------------------------------- */

static inline bool aes67_pci_wb_addr_ok(u32 addr)
{
	return addr >= AES67_PCIE_WB_BASE &&
	       addr < AES67_PCIE_WB_BASE + AES67_PCIE_WB_SIZE;
}

static int aes67_pci_read(struct aes67_priv *p, u32 addr, u32 *val)
{
	if (!aes67_pci_wb_addr_ok(addr))
		return -EINVAL;
	*val = ioread32(p->bar + AES67_PCIE_WB_OFFSET + (addr - AES67_PCIE_WB_BASE));
	return 0;
}

static int aes67_pci_write(struct aes67_priv *p, u32 addr, u32 val)
{
	if (!aes67_pci_wb_addr_ok(addr))
		return -EINVAL;
	iowrite32(val, p->bar + AES67_PCIE_WB_OFFSET + (addr - AES67_PCIE_WB_BASE));
	return 0;
}

/* eth_buf stores one frame byte per 32-bit word. Posted MMIO writes stream
 * nicely; reads are one non-posted PCIe transaction each (~1 us), i.e. about
 * 1.5 ms per full-size control-plane frame — fine for PTP/SAP/mDNS rates. */
static int aes67_pci_write_burst(struct aes67_priv *p, u32 addr,
				 const u8 *bytes, unsigned int n)
{
	void __iomem *base;
	unsigned int i;

	if (!aes67_pci_wb_addr_ok(addr) || !aes67_pci_wb_addr_ok(addr + 4 * n - 4))
		return -EINVAL;
	base = p->bar + AES67_PCIE_WB_OFFSET + (addr - AES67_PCIE_WB_BASE);
	for (i = 0; i < n; i++)
		iowrite32(bytes[i], base + 4 * i);
	return 0;
}

static int aes67_pci_read_burst(struct aes67_priv *p, u32 addr,
				u8 *bytes, unsigned int n)
{
	void __iomem *base;
	unsigned int i;

	if (!aes67_pci_wb_addr_ok(addr) || !aes67_pci_wb_addr_ok(addr + 4 * n - 4))
		return -EINVAL;
	base = p->bar + AES67_PCIE_WB_OFFSET + (addr - AES67_PCIE_WB_BASE);
	for (i = 0; i < n; i++)
		bytes[i] = ioread32(base + 4 * i) & 0xff;
	return 0;
}

static const struct aes67_bus_ops aes67_pci_bus_ops = {
	.name        = "pcie",
	.read        = aes67_pci_read,
	.write       = aes67_pci_write,
	.read_burst  = aes67_pci_read_burst,
	.write_burst = aes67_pci_write_burst,
};

/* --- interrupts ----------------------------------------------------------- */

static inline void __iomem *ctl_reg(struct aes67_priv *p, u32 off)
{
	return p->bar + AES67_PCIE_CTL_OFFSET + off;
}

static irqreturn_t aes67_pci_irq(int irq, void *data)
{
	struct aes67_pci *ap = data;
	struct aes67_priv *p = ap->p;
	u32 status = ioread32(ctl_reg(p, AES67_CTL_IRQ_STATUS));

	status &= ap->irq_enable;
	if (!status)
		return IRQ_NONE;

	if (status & AES67_IRQ_W1C_MASK)
		iowrite32(status & AES67_IRQ_W1C_MASK, ctl_reg(p, AES67_CTL_IRQ_STATUS));

	aes67_pcm_irq(p, status);

	if (status & AES67_IRQ_ETH_BUF) {
		/* Level source: mask it until the thread has drained eth_buf,
		 * otherwise the gateware re-raises the MSI every few hundred ns. */
		iowrite32(ap->irq_enable & ~AES67_IRQ_ETH_BUF, ctl_reg(p, AES67_CTL_IRQ_ENABLE));
		return IRQ_WAKE_THREAD;
	}
	return IRQ_HANDLED;
}

static irqreturn_t aes67_pci_irq_thread(int irq, void *data)
{
	struct aes67_pci *ap = data;

	aes67_netdev_service(ap->p);
	iowrite32(ap->irq_enable, ctl_reg(ap->p, AES67_CTL_IRQ_ENABLE));
	return IRQ_HANDLED;
}

/* --- probe / remove ------------------------------------------------------- */

static int aes67_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct aes67_pci *ap;
	struct aes67_priv *p;
	u32 idreg, ver;
	int ret;

	ret = pcim_enable_device(pdev);
	if (ret)
		return ret;
	pci_set_master(pdev);

	if (pci_resource_len(pdev, 0) < AES67_PCIE_BAR_SIZE) {
		dev_err(&pdev->dev, "BAR0 too small (%llu)\n",
			(unsigned long long)pci_resource_len(pdev, 0));
		return -ENODEV;
	}

	ap = devm_kzalloc(&pdev->dev, sizeof(*ap), GFP_KERNEL);
	if (!ap)
		return -ENOMEM;
	ap->pdev = pdev;

	p = aes67_alloc(&pdev->dev);
	if (!p)
		return -ENOMEM;
	ap->p = p;
	p->ops = &aes67_pci_bus_ops;
	p->irq_external = true;
	p->poll_ms = 20;   /* backstop only; RX is interrupt driven */

	p->bar = pcim_iomap_region(pdev, 0, "aes67");
	if (IS_ERR(p->bar)) {
		ret = PTR_ERR(p->bar);
		goto err_free;
	}

	idreg = ioread32(ctl_reg(p, AES67_CTL_ID));
	ver   = ioread32(ctl_reg(p, AES67_CTL_VERSION));
	if (idreg != AES67_CTL_ID_VALUE) {
		dev_err(&pdev->dev, "unexpected ID register 0x%08x (gateware not loaded?)\n", idreg);
		ret = -ENODEV;
		goto err_free;
	}

	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret)
		ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret) {
		dev_err(&pdev->dev, "no usable DMA mask\n");
		goto err_free;
	}

	/* Quiet the interrupt sources before anything is registered. */
	ap->irq_enable = 0;
	iowrite32(0, ctl_reg(p, AES67_CTL_IRQ_ENABLE));
	iowrite32(AES67_IRQ_W1C_MASK, ctl_reg(p, AES67_CTL_IRQ_STATUS));

	ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI | PCI_IRQ_INTX);
	if (ret < 0)
		goto err_free;
	ap->irq = pci_irq_vector(pdev, 0);

	pci_set_drvdata(pdev, ap);

	ret = aes67_core_probe(p);
	if (ret)
		goto err_vectors;

	ret = request_threaded_irq(ap->irq, aes67_pci_irq, aes67_pci_irq_thread,
				   IRQF_SHARED, "aes67_pcie", ap);
	if (ret) {
		dev_err(&pdev->dev, "request_irq(%d) failed: %d\n", ap->irq, ret);
		goto err_core;
	}

	ret = aes67_pcm_register(p);
	if (ret)
		dev_warn(&pdev->dev, "ALSA card not registered: %d\n", ret);

	ap->irq_enable = AES67_IRQ_ETH_BUF | AES67_IRQ_W1C_MASK;
	iowrite32(ap->irq_enable, ctl_reg(p, AES67_CTL_IRQ_ENABLE));

	dev_info(&pdev->dev, "AES67 PCIe card, gateware %u.%u, IRQ %d (%s)\n",
		 ver >> 16, ver & 0xffff, ap->irq,
		 pdev->msi_enabled ? "MSI" : "INTx");
	return 0;

err_core:
	aes67_core_remove(p);
err_vectors:
	pci_free_irq_vectors(pdev);
err_free:
	aes67_free(p);
	return ret;
}

static void aes67_pci_remove(struct pci_dev *pdev)
{
	struct aes67_pci *ap = pci_get_drvdata(pdev);
	struct aes67_priv *p = ap->p;

	ap->irq_enable = 0;
	iowrite32(0, ctl_reg(p, AES67_CTL_IRQ_ENABLE));
	/* Stop the DMA engine so it never touches freed host memory. */
	iowrite32(0, p->bar + AES67_PCIE_DMA_OFFSET + AES67_DMA_CTRL);

	aes67_pcm_unregister(p);
	free_irq(ap->irq, ap);
	aes67_core_remove(p);
	pci_free_irq_vectors(pdev);
	aes67_free(p);
}

static const struct pci_device_id aes67_pci_ids[] = {
	{ PCI_DEVICE(AES67_PCI_VENDOR_ID, AES67_PCI_DEVICE_ID) },
	{ }
};
MODULE_DEVICE_TABLE(pci, aes67_pci_ids);

static struct pci_driver aes67_pci_driver = {
	.name     = "aes67_pcie",
	.id_table = aes67_pci_ids,
	.probe    = aes67_pci_probe,
	.remove   = aes67_pci_remove,
};

int aes67_pci_register(void)
{
	return pci_register_driver(&aes67_pci_driver);
}

void aes67_pci_unregister(void)
{
	pci_unregister_driver(&aes67_pci_driver);
}
