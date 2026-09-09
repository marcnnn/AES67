# Alibaba Cloud AS02MC04 (XCKU3P) as a PCIe AES67 sound card

Board: "Alibaba Accelerator Card R1291-F9003-02", Kintex UltraScale+
`XCKU3P-FFVB676-1E` (some batches `-2E`), PCIe Gen3 x8 edge connector, two
SFP28 cages, 100 MHz LVDS oscillator, 156.25 MHz SFP reference, MT25QU256 QSPI
flash, no DDR, no audio pins. It was decommissioned cloud hardware and has no
vendor documentation; the pinout in `alibaba_ku3p.xdc` comes from the
community notes linked in that file.

The card is used as a **host-attached AES67 endpoint**:

| Function            | Implementation                                                         |
|---------------------|------------------------------------------------------------------------|
| Network             | SFP cage 1, Xilinx 1G PCS/PMA (1000BASE-X) -> GMII -> repo MAC          |
| Data plane          | unchanged `aes67_top` / `aes67_wb_bridge` (`PTP_IN_SOFTWARE = true`)    |
| Control plane       | Linux host over PCIe: XDMA (AXI bridge) -> `pcie_axi_slave` -> Wishbone |
| PTP                 | `ptp4l` on the host disciplines the FPGA wallclock through the PHC      |
| Audio I/O           | `pcie_audio_dma`: bus-mastering ring buffers in host memory, ALSA card  |
| Config / discovery  | unchanged Rust `config_tool` on top of `/dev/aes67ctl`                  |

`global_system_cfg_alibaba_ku3p` in `FPGA/packages/system_cfg_pkg.vhd`
selects everything: `PLATFORM => XILINX`, `CLK_IN_SPEED => 100`, the GMII PHY
config (`std_sfp_pcs_cfg`) and the parallel audio interface with 32 playback
and 32 capture channels (`audio_config_pcie`). Change the channel counts there;
`CHANNELS * 32` must stay a multiple of the 128-bit AXI width.

## BAR0 layout (4 MiB)

| Offset     | Block                                  | Source                             |
|------------|----------------------------------------|------------------------------------|
| `0x000000` | LiteX aes67_bridge window (128 KiB used), byte address `0x90000000 + offset` | `FPGA/pcie/simplebus_wb_master.vhd` |
| `0x100000` | audio DMA engine registers             | `FPGA/pcie/pcie_audio_dma.vhd`     |
| `0x200000` | board / interrupt control registers    | `FPGA/pcie/pcie_ctrl_regs.vhd`     |

The register maps are documented in the headers of those two files and
mirrored by `driver/aes67_eth/aes67_pcie_regs.h`.

## Build

```sh
# 1. LiteX bridge for the Xilinx family (FDPE reset cells instead of Altera DFF)
source soc_firmware/.venv/bin/activate
python litex_soc/generate.py --target aes67_bridge --family xilinx
# 2. kernel register header from the resulting csr.csv
make -C driver/aes67_eth regs CSV=../../litex_soc/build/aes67_bridge_xilinx/csr.csv
# 3. gateware (Vivado 2023.2+, free licence covers the KU3P)
cd FPGA/boards/xilinx/alibaba_ku3p
vivado -mode batch -source build.tcl
```

`build.tcl` creates the project in `build/`, generates the two IP cores
(`xdma_0` in AXI-Bridge mode, `gig_eth_pcs_pma_0`), runs synthesis and
implementation and writes `build/aes67_ku3p.bit` plus a QSPI image
`build/aes67_ku3p.mcs`. Use `-tclargs -project` to only create the project and
finish interactively.

What has been verified without hardware: the whole VHDL tree analyses and
the board top elaborates with GHDL, the PCIe register path and the audio DMA
engine pass their testbenches (`FPGA/pcie/tb/run_sims.sh`: AXI lanes/bursts,
Wishbone translation and watchdog, IRQ handshake, playback/capture rings
across wrap, 4 KiB burst splitting, host stalls, period interrupts, for 8/16/32
channels), the LiteX bridge generates for the Xilinx family with the same CSR
map as the committed `aes67_regs.h`, and the kernel module builds warning-free.

Things to check on the first build (no hardware was available while this port
was written):

* The IP port lists declared as components in `top_alibaba_ku3p.vhd` were
  written against PG194 (xdma v4.x, AXI Bridge mode) and PG047 (PCS/PMA
  v16.x). If Vivado reports a port mismatch, copy the instantiation template
  from the generated IP (`.vho`) into the component declaration.
* The XDMA property names in `build.tcl` differ slightly between Vivado
  releases; `report_property [get_ips xdma_0]` lists the valid ones.
* Lane order on this card is reversed. The PCIe hard block handles lane
  reversal, but the community notes only got x4 to train reliably, hence the
  Gen2 x4 default. If the link does not train at all, try PERST on `T19`
  instead of `A9` (both have been reported).
* LEDs are assumed active low (`LED_ACTIVE_LOW` generic).

## Program

```sh
# JTAG (volatile): the on-board 6-pin header, see the community notes for the
# non-standard layout
vivado -mode batch -source program.tcl        # or Hardware Manager
# QSPI (persistent, required so the card enumerates when the host boots):
# Hardware Manager -> Add Configuration Memory Device -> mt25qu256-spi-x1_x2_x4
# -> program build/aes67_ku3p.mcs, then power-cycle the host (not just reboot).
```

## Host side

```sh
cd driver/aes67_eth && make && sudo insmod aes67_eth_drv.ko
lspci -d 10ee:ae67 -v          # BAR0 4 MiB, MSI
ip link                        # aes67 netdev (control plane, PTP, SAP, RTSP)
ethtool -T <if>                # HW timestamping + PHC index
sudo ptp4l -H -i <if> -m       # disciplines the FPGA wallclock
aplay -l                       # "AES67" card: 32 ch playback / 32 ch capture, S32_LE 48 kHz
```

Then run `aes67d` / `aes67cfg` / `aes67web` from `config_tool/` exactly as on
the Raspberry Pi setup: they reach the FPGA registers through
`/dev/aes67ctl`, which the same kernel module provides over PCIe.
Playback channel *n* of the ALSA device feeds AES67 TX channel *n*; AES67 RX
channel *n* appears as capture channel *n*. Stream routing (which channels go
into which RTP stream) is configured with `aes67cfg` as before.
