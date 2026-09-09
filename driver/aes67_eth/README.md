# aes67_eth — FPGA Ethernet + PHC (+ PCIe sound card) kernel driver

Out-of-tree Linux driver that turns the AES67 FPGA (CPU-less `aes67_bridge`
target; FPGA top built with `PTP_IN_SOFTWARE = true`) into a first-class network
device with **hardware PTP timestamping**, so stock **`ptp4l`** can discipline
the FPGA wallclock. This is Phase 5 ("PTP offload to the SoC") of
`config_tool/docs/control-plane-plan.md`.

One module, two bus backends:

| Backend   | File           | Hardware                                             | Extra                         |
|-----------|----------------|------------------------------------------------------|-------------------------------|
| `spibone` | `aes67_spi.c`  | SPI link to an external FPGA board (Raspberry Pi)    | DT overlay, optional IRQ GPIO |
| `pcie`    | `aes67_pci.c`  | Alibaba KU3P PCIe card (`FPGA/boards/xilinx/alibaba_ku3p`) | MSI, ALSA card (`aes67_pcm.c`) |

## What it provides

- **`net_device`** carrying the FPGA `eth_buf` control-plane datapath (the same
  RX-drain / TX-inject protocol the userspace daemon used, now in-kernel).
- **PHC** (`/dev/ptpN`, clock name `aes67_wallclock`) mapping the wallclock CSRs:
  `gettime`/`settime`/`adjtime` (phase jump) / `adjfine` (ppb).
- **HW timestamps**: TX from the `tx_timestamp_*` CSRs, RX from the 5-byte
  trailer the FPGA appends after the payload. The captured 4-bit seconds are
  extended to full time by reading the live wallclock seconds.
- **`/dev/aes67ctl`**: a peek/poke char device so the userspace daemon
  (`aes67d`) and `aes67cfg` keep reaching FPGA registers now that the **kernel
  owns the bus** (single Wishbone master).
- **ALSA card** (PCIe only): the card's bus-mastering audio DMA engine as a
  PCM device, interleaved S32_LE at 48 kHz, one playback and one capture
  substream with as many channels as the gateware was built with (default 32).
  Playback channel *n* feeds AES67 TX channel *n*; AES67 RX channel *n* is
  capture channel *n*.

## Build

```sh
make                      # against the running kernel
make KDIR=<target-headers> ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-   # cross
make regs CSV=../../litex_soc/build/aes67_bridge/csr.csv          # regenerate aes67_regs.h
make regs CSV=../../litex_soc/build/aes67_bridge_xilinx/csr.csv   # (PCIe card build)
```

`aes67_regs.h` is generated from the LiteX `csr.csv` so register addresses track
`litex_soc/generate.py` (they shift when CSRs are added/removed). Regenerate it
whenever the gateware CSR map changes. `aes67_pcie_regs.h` describes the two
extra BAR0 register blocks of the PCIe card and is maintained by hand together
with `FPGA/pcie/pcie_audio_dma.vhd` / `pcie_ctrl_regs.vhd`.

The backends are compiled in when the kernel has `CONFIG_SPI` / `CONFIG_PCI`
(and `CONFIG_SND_PCM` for the ALSA part); a kernel without one of them simply
loses that backend.

## Wiring

**spibone**: bind via a device-tree overlay (`dts/aes67-overlay.dts`): an SPI
child node with `compatible = "aes67,spibone"`. Wire `eth_buf_irq` to a GPIO and
list it under `interrupts` for interrupt-driven RX; otherwise the driver polls
(`poll_ms`).

**pcie**: nothing to configure; the card enumerates as PCI `10ee:ae67`
(class multimedia/audio) with a 4 MiB BAR0 and one MSI vector. The driver
checks the gateware ID register before touching anything.

## Use with ptp4l

```sh
insmod aes67_eth_drv.ko
ethtool -T eth0          # shows HW TX/RX + a PHC index
ptp4l -H -i eth0 -m      # hardware timestamping, disciplines the FPGA wallclock
```

## Audio (PCIe)

```sh
aplay -l                                  # card "AES67"
aplay -D hw:AES67 -f S32_LE -r 48000 -c 32 file.wav
arecord -D hw:AES67 -f S32_LE -r 48000 -c 32 -d 10 cap.wav
```

`hw:AES67` insists on the native channel count; use a `plug`/`dmix` PCM in
`~/.asoundrc` to play stereo material. The engine's playback pointer lags the
real playout position by its prefetch FIFO (a few frames), so the smallest
period is limited accordingly (see `period_bytes_min` in `aes67_pcm.c`).

## Module parameters

- `poll_ms` (default 1): RX poll interval when no IRQ is wired (spibone). The
  PCIe backend is interrupt driven and only uses a 20 ms backstop poll.
- `rx_ts` (default 1): parse the FPGA RX hardware-timestamp trailer. Set to 0
  until the FPGA RX FSM appends the trailer (see the FPGA dependency below).
- `rx_strip` (default 4): trailing FCS bytes to drop from each RX frame.
- `spi_hz`, `use_burst`: spibone link speed and burst-command use.

## FPGA dependency

The driver expects the RX buffer layout `payload | FCS(4) | seconds(1) |
nanoseconds_LE(4)`, with `eth_buf_rx_len` counting all of it. The trailer is
produced by the `RX_WRITE_SECONDS`/`RX_WRITE_NANOSECONDS` states in
`FPGA/litex_eth_buffer_bridge.vhd`; confirm those are reachable and that
`buf_rx_len` includes the 5 trailer bytes before relying on RX timestamps
(`rx_ts=1`).
