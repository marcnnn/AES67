/* SPDX-License-Identifier: GPL-2.0 */
/*
 * AES67 FPGA Ethernet + PHC (+ ALSA) driver — shared definitions.
 *
 * The FPGA (CPU-less aes67_bridge target, built with PTP_IN_SOFTWARE) is
 * reached over one of two buses, both ending in the same LiteX Wishbone
 * register window:
 *
 *   spibone : SPI link (Raspberry Pi + external FPGA board). Every access is
 *             an SPI transfer that sleeps.
 *   pcie    : the FPGA is a PCIe card (Alibaba KU3P); the window is memory
 *             mapped in BAR0 and the card also carries a bus-mastering audio
 *             DMA engine that becomes an ALSA card.
 *
 * This driver is the sole Wishbone master either way: it carries the eth_buf
 * control-plane datapath as a netdev, exposes the FPGA wallclock as a PHC,
 * and hardware-timestamps PTP frames so stock ptp4l can discipline the clock.
 * Config traffic from userspace rides the same bus through /dev/aes67ctl.
 */
#ifndef AES67_ETH_H
#define AES67_ETH_H

#include <linux/miscdevice.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/ptp_clock_kernel.h>
#include <linux/skbuff.h>
#include <linux/spi/spi.h>
#include <linux/workqueue.h>

#include "aes67_regs.h"

/* --- Gateware register-bit contract (see FPGA/aes67_csr.py) --------------- */
#define AES67_CTRL_ETH_TX_REQUEST  BIT(3)   /* aes67_csr_ctrl: pulse to send TX */
#define AES67_STATUS_ETH_LINK_UP   BIT(4)   /* aes67_csr_status: PHY link up    */
#define AES67_STATUS_ETH_TX_DONE   BIT(7)   /* aes67_csr_status: last TX done   */
#define AES67_EV_RX_READY          BIT(0)   /* eth_buf EventManager: RX ready   */
#define AES67_WC_CTRL_SET          BIT(0)   /* wallclock_ctrl: load out regs    */
#define AES67_WC_CTRL_PHASEJUMP    BIT(1)   /* wallclock_ctrl: add signed delta */

#define AES67_TX_REGION_OFFSET     0x2000u  /* TX buffer base within eth_buf    */

/* RX framing. The MAC includes the 4-byte FCS in the buffer; the FPGA appends a
 * 5-byte hardware-timestamp trailer after it (1 byte seconds[3:0], then 4 bytes
 * little-endian nanoseconds[29:0]). rx_len counts payload + FCS + trailer.
 * NOTE: this is the contract the FPGA RX FSM must honour (see plan / the
 * litex_eth_buffer_bridge.vhd RX_WRITE_* states). */
#define AES67_FCS_LEN              4
#define AES67_RX_TS_TRAILER_LEN    5
#define AES67_WC_SEC_CAP_BITS      4        /* captured seconds field width     */

#define AES67_MAX_FRAME            1518

/* adjfine: the wallclock_ppb output is signed 20-bit (parts-per-billion). */
#define AES67_MAX_PPB              ((1 << 19) - 1)   /* +/- 524287 ppb */

/* --- SPI burst transfers (spibone burst read/write) ----------------------- *
 * The frame RX/TX hot paths move one eth_buf byte per 32-bit word. spibone's
 * burst commands (0x02 write / 0x03 read) stream many words in a single SPI
 * transfer, auto-incrementing the word address in gateware, instead of one
 * spi_sync round-trip per word. A per-device DMA-safe scratch pair holds one
 * chunk; bus_lock serialises their use. The chunk sizes keep every transfer
 * within AES67_BURST_BUF including framing + response slack:
 *   write: 7 (cmd+addr+count) + 4*N (data) + 8  (ack slack)
 *   read:  7 (header echo)    + 7*N (<=pad+sync+4 data) + 16 (slack) */
#define AES67_BURST_BUF        2048u
#define AES67_BURST_WR_CHUNK   256u   /* 7 + 4*256 + 8  = 1039 B */
#define AES67_BURST_RD_CHUNK   240u   /* 7 + 7*240 + 16 = 1703 B */

struct aes67_priv;

/* --- Bus backend ---------------------------------------------------------- *
 * All ops are called with bus_lock held and may sleep (they run in process
 * context only). Addresses are Wishbone byte addresses from aes67_regs.h. The
 * burst ops move `n` consecutive 32-bit words, one eth_buf byte per word. */
struct aes67_bus_ops {
	const char *name;
	int (*read)(struct aes67_priv *p, u32 addr, u32 *val);
	int (*write)(struct aes67_priv *p, u32 addr, u32 val);
	int (*read_burst)(struct aes67_priv *p, u32 addr, u8 *bytes, unsigned int n);
	int (*write_burst)(struct aes67_priv *p, u32 addr, const u8 *bytes, unsigned int n);
};

/* --- Driver private state ------------------------------------------------- */
struct aes67_priv {
	struct device       *dev;
	const struct aes67_bus_ops *ops;
	struct net_device   *netdev;

	/* spibone backend */
	struct spi_device   *spi;
	u8 *spi_tx;      /* DMA-safe scratch for SPI burst transfers */
	u8 *spi_rx;

	/* pcie backend */
	void __iomem        *bar;
	void                *pcm;    /* struct aes67_pcm (aes67_pcm.c), if built */

	/* Serialises every Wishbone access: netdev RX/TX bursts, PHC ops, and
	 * the /dev/aes67ctl peek/poke. The whole bus has a single owner. */
	struct mutex         bus_lock;

	/* All bus I/O runs in process context: an ordered wq drains the software
	 * TX queue and the poll fallback; a threaded IRQ drains RX. */
	struct workqueue_struct *wq;
	struct sk_buff_head      txq;
	struct work_struct       tx_work;
	struct delayed_work      poll_work;
	int                      irq;        /* netdev-owned IRQ (spibone); 0 = none */
	bool                     irq_external; /* bus backend delivers RX events itself */
	unsigned int             poll_ms;    /* RX poll interval (backstop) */

	/* Scratch buffer for one RX frame (payload + FCS + timestamp trailer). */
	u8 rx_buf[AES67_MAX_FRAME + AES67_FCS_LEN + AES67_RX_TS_TRAILER_LEN];

	/* PHC */
	struct ptp_clock      *ptp_clock;
	struct ptp_clock_info  ptp_info;

	/* HW timestamping enables (set via SIOCSHWTSTAMP). The FPGA keeps only
	 * the *last* TX timestamp, so timestamped TX is serialised by the wq. */
	spinlock_t            tx_ts_lock;
	bool                  hwts_tx_on;
	bool                  hwts_rx_on;

	/* Control char device (/dev/aes67ctl). */
	struct miscdevice     ctl_dev;
};

/* --- Bus layer (aes67_bus.c) ---------------------------------------------- *
 * The _locked variants assume bus_lock is held (for multi-word sequences); the
 * plain variants take it for a single transaction. They dispatch to p->ops. */
int  aes67_wb_read_locked(struct aes67_priv *p, u32 addr, u32 *val);
int  aes67_wb_write_locked(struct aes67_priv *p, u32 addr, u32 val);
int  aes67_wb_read(struct aes67_priv *p, u32 addr, u32 *val);
int  aes67_wb_write(struct aes67_priv *p, u32 addr, u32 val);
int  aes67_wb_write_burst_locked(struct aes67_priv *p, u32 addr,
				 const u8 *bytes, unsigned int n);
int  aes67_wb_read_burst_locked(struct aes67_priv *p, u32 addr,
				u8 *bytes, unsigned int n);

int  aes67_ctl_register(struct aes67_priv *p);
void aes67_ctl_unregister(struct aes67_priv *p);

/* --- Core (aes67_eth.c) --------------------------------------------------- *
 * Backends allocate the netdev + priv with aes67_alloc(), fill in dev/ops/irq
 * (and their own fields), then call aes67_core_probe(). */
struct aes67_priv *aes67_alloc(struct device *dev);
void aes67_free(struct aes67_priv *p);
int  aes67_core_probe(struct aes67_priv *p);
void aes67_core_remove(struct aes67_priv *p);
/* Drain pending RX frames + refresh carrier. Process context; used by
 * backends that receive the eth_buf interrupt themselves. */
void aes67_netdev_service(struct aes67_priv *p);

/* --- Backends ------------------------------------------------------------- */
#if IS_ENABLED(CONFIG_SPI)
int  aes67_spi_register(void);
void aes67_spi_unregister(void);
#else
static inline int aes67_spi_register(void) { return 0; }
static inline void aes67_spi_unregister(void) { }
#endif

#if IS_ENABLED(CONFIG_PCI)
int  aes67_pci_register(void);
void aes67_pci_unregister(void);
#else
static inline int aes67_pci_register(void) { return 0; }
static inline void aes67_pci_unregister(void) { }
#endif

/* --- ALSA PCM on the PCIe audio DMA engine (aes67_pcm.c) ------------------ */
#if IS_ENABLED(CONFIG_SND_PCM)
int  aes67_pcm_register(struct aes67_priv *p);
void aes67_pcm_unregister(struct aes67_priv *p);
/* Called from the PCIe hard IRQ handler with the W1C status bits. */
void aes67_pcm_irq(struct aes67_priv *p, u32 status);
#else
static inline int aes67_pcm_register(struct aes67_priv *p) { return 0; }
static inline void aes67_pcm_unregister(struct aes67_priv *p) { }
static inline void aes67_pcm_irq(struct aes67_priv *p, u32 status) { }
#endif

/* --- PHC (aes67_phc.c) ---------------------------------------------------- */
int  aes67_phc_register(struct aes67_priv *p);
void aes67_phc_unregister(struct aes67_priv *p);
/* Reconstruct a full 64-bit ns timestamp from a captured (4-bit sec, 30-bit ns)
 * pair by reading the live wallclock seconds. Used by RX and TX timestamping.
 * Takes bus_lock internally. */
int  aes67_ts_reconstruct(struct aes67_priv *p, u8 cap_sec, u32 cap_nsec,
			  u64 *ns_out);

#endif /* AES67_ETH_H */
