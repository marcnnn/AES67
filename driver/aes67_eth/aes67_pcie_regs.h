/* SPDX-License-Identifier: GPL-2.0 */
/*
 * BAR0 layout of the PCIe AES67 card (FPGA/boards/xilinx/alibaba_ku3p).
 * Mirrors FPGA/pcie/pcie_sb_decoder.vhd, pcie_audio_dma.vhd and
 * pcie_ctrl_regs.vhd — keep them in sync.
 */
#ifndef AES67_PCIE_REGS_H
#define AES67_PCIE_REGS_H

#define AES67_PCI_VENDOR_ID        0x10ee
#define AES67_PCI_DEVICE_ID        0xae67

#define AES67_PCIE_BAR_SIZE        0x400000u

/* Region 0: LiteX aes67_bridge Wishbone window, byte address 0x90000000 + off */
#define AES67_PCIE_WB_OFFSET       0x000000u
#define AES67_PCIE_WB_BASE         0x90000000u
#define AES67_PCIE_WB_SIZE         0x100000u

/* Region 1: audio DMA engine */
#define AES67_PCIE_DMA_OFFSET      0x100000u
#define AES67_DMA_CTRL             0x00
#define   AES67_DMA_CTRL_PB_RUN      BIT(0)
#define   AES67_DMA_CTRL_CAP_RUN     BIT(1)
#define AES67_DMA_STATUS           0x04
#define   AES67_DMA_STATUS_PB_UNDERRUN BIT(4)
#define   AES67_DMA_STATUS_CAP_OVERRUN BIT(5)
#define   AES67_DMA_STATUS_AXI_ERR     BIT(6)
#define AES67_DMA_CAPS             0x08
#define   AES67_DMA_CAPS_PB_CH(v)    ((v) & 0xff)
#define   AES67_DMA_CAPS_CAP_CH(v)   (((v) >> 8) & 0xff)
#define   AES67_DMA_CAPS_BEAT_BYTES(v) (((v) >> 16) & 0xff)
#define   AES67_DMA_CAPS_FIFO_BITS(v)  (((v) >> 24) & 0xff)
#define AES67_DMA_BURST            0x0c
#define AES67_DMA_PB_ADDR_LO       0x10
#define AES67_DMA_PB_ADDR_HI       0x14
#define AES67_DMA_PB_RING          0x18
#define AES67_DMA_PB_PERIOD        0x1c
#define AES67_DMA_PB_HW_PTR        0x20
#define AES67_DMA_PB_UNDERRUNS     0x24
#define AES67_DMA_CAP_ADDR_LO      0x30
#define AES67_DMA_CAP_ADDR_HI      0x34
#define AES67_DMA_CAP_RING         0x38
#define AES67_DMA_CAP_PERIOD       0x3c
#define AES67_DMA_CAP_HW_PTR       0x40
#define AES67_DMA_CAP_OVERRUNS     0x44
#define AES67_DMA_FS_COUNT         0x50

/* Region 2: board / interrupt control */
#define AES67_PCIE_CTL_OFFSET      0x200000u
#define AES67_CTL_ID               0x00
#define   AES67_CTL_ID_VALUE         0xae670001u
#define AES67_CTL_VERSION          0x04
#define AES67_CTL_IRQ_STATUS       0x08
#define AES67_CTL_IRQ_ENABLE       0x0c
#define   AES67_IRQ_ETH_BUF          BIT(0)   /* level, cleared by servicing eth_buf */
#define   AES67_IRQ_PB_PERIOD        BIT(1)   /* W1C */
#define   AES67_IRQ_CAP_PERIOD       BIT(2)   /* W1C */
#define   AES67_IRQ_PB_UNDERRUN      BIT(3)   /* W1C */
#define   AES67_IRQ_CAP_OVERRUN      BIT(4)   /* W1C */
#define   AES67_IRQ_W1C_MASK         (AES67_IRQ_PB_PERIOD | AES67_IRQ_CAP_PERIOD | \
				      AES67_IRQ_PB_UNDERRUN | AES67_IRQ_CAP_OVERRUN)
#define AES67_CTL_LEDS             0x10
#define AES67_CTL_SFP_STATUS       0x14
#define AES67_CTL_PCS_CTRL         0x18
#define AES67_CTL_LINK_STATUS      0x1c
#define AES67_CTL_SCRATCH          0x20

#endif /* AES67_PCIE_REGS_H */
