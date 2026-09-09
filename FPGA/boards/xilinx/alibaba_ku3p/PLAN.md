# Bring-up plan: Alibaba AS02MC04 (XCKU3P) as PCIe AES67 sound card

Status as of 2026-09-09. Everything below the "Verified" line was done on a
laptop without the card and without Vivado; the rest is meant to run on the
desktop that will host the card.

## Goal

The card becomes a Linux sound card whose channels are AES67 network channels:
`aplay`/`arecord`/PipeWire see a 32 in / 32 out S32_LE 48 kHz device, the
host runs `ptp4l`, `aes67d`, `aes67cfg` and `aes67web` exactly as on the
Raspberry Pi setup, and the FPGA does the whole data plane (MAC, timestamping,
RTP, media clock) as before.

## Architecture (what was built)

| Piece | Files | Notes |
|-------|-------|-------|
| Network port | Xilinx 1G PCS/PMA (1000BASE-X) on SFP cage 1, GMII to the repo MAC | `mii_converters.vhd` GMII branch, `std_sfp_pcs_cfg` in `system_cfg_pkg.vhd` |
| Data plane | unchanged `wb_bridge_top` / `aes67_top`, `PTP_IN_SOFTWARE = true` | `global_system_cfg_alibaba_ku3p` selects XILINX platform, 100 MHz input, parallel audio |
| Clocks | MMCM branch in `sysclk_pll_gen.vhd`: 100 MHz -> 125 MHz sys, 75 MHz LiteX | PCIe user clock and PCS clock are separate, all crossings synchronised |
| Host bus | XDMA IP in AXI-Bridge mode -> `pcie_axi_slave` -> `pcie_sb_decoder` -> `simplebus_wb_master` -> LiteX `aes67_bridge` | BAR0 offset 0 = Wishbone byte address 0x90000000 + offset, so `aes67_regs.h` is unchanged |
| Audio | `pcie_audio_dma.vhd`: bus-mastering ring buffers in host RAM <-> parallel sample registers | S32_LE interleaved, period IRQs, underrun/overrun counters |
| Board regs / IRQ | `pcie_ctrl_regs.vhd`: ID, version, IRQ status/enable, LEDs, SFP and PCS status | one MSI vector, XDMA usr_irq_req/ack handshake |
| Board | `top_alibaba_ku3p.vhd`, `alibaba_ku3p.xdc`, `build.tcl`, `program.tcl` | pinout from the community reverse-engineering notes |
| LiteX | `--family xilinx` for the CPU-less targets | emits FDPE/FDCE reset cells |
| Driver | `driver/aes67_eth`: bus-agnostic core, `aes67_spi.c`, `aes67_pci.c`, `aes67_pcm.c` | one module serves both the Pi/SPI setup and the PCIe card |

BAR0 map: `0x000000` Wishbone window, `0x100000` audio DMA registers,
`0x200000` control registers. Register bit layouts are documented in the
headers of the two VHDL files and mirrored in `aes67_pcie_regs.h`.

## Verified (no hardware)

- GHDL 6 analyses the whole VHDL tree and elaborates the board top.
- `FPGA/pcie/tb/run_sims.sh`: register path (AXI lanes, 64-bit and burst
  accesses, Wishbone translation, watchdog, error responses, IRQ handshake)
  and audio DMA (playback/capture rings across wrap, 4 KiB burst splitting,
  host stalls, underrun accounting, period IRQs) pass for 8/16/32 channels.
  One real bug was found and fixed this way (per-beat fetch accounting).
- LiteX `aes67_bridge --family xilinx` generates; CSR map identical to the
  committed `aes67_regs.h`; Verilog ports match the VHDL component.
- Kernel module builds warning-free (`W=1`) on Linux 7.2 with SPI, PCI and
  ALSA backends.

## Not verified

- Vivado synthesis/implementation, timing.
- The component port lists of `xdma_0` and `gig_eth_pcs_pma_0` in the board
  top (written from PG194 / PG047) and the IP property names in `build.tcl`.
- PCIe link training on this card (reversed lanes; community reports x4 works,
  x8 not; PERST reported on A9 by some, T19 by others).
- SFP link: 1000BASE-X autoneg against the switch, MDIO status polling by the
  MAC, PCS refclk 156.25 MHz option.
- LED polarity, bank voltages (LVCMOS18 vs 3.3 V rails).
- Audio timing on the real media clock, ALSA period behaviour, PTP lock.

## Desktop bring-up, step by step

### 0. Machine prerequisites

- Linux with kernel headers, gcc, make, git, python3, cargo (rustup).
- Vivado ML Standard 2023.2+ with "Kintex UltraScale+" devices (free licence).
  16 GB RAM minimum for implementation, 32 GB comfortable.
- `linuxptp`, `alsa-utils`, optionally `ghdl` for the simulations.
- Hardware: the card in a x4 or longer slot, a JTAG probe on the 6-pin header
  (Digilent HS2/HS3, Xilinx Platform Cable, or J-Link + OpenOCD per the
  community notes), a 1 Gbit SFP module (not the 25G one shipped with the
  card), an AES67-capable switch or a direct link to another AES67 device.

### 1. Repository

```sh
git clone --recurse-submodules git@github.com:malarisch/AES67.git
cd AES67 && git checkout test
python3 -m venv soc_firmware/.venv
soc_firmware/.venv/bin/pip install "migen @ git+https://github.com/m-labs/migen" "litex @ git+https://github.com/enjoy-digital/litex"
soc_firmware/.venv/bin/python litex_soc/generate.py --target aes67_bridge --family xilinx
make -C driver/aes67_eth regs CSV=../../litex_soc/build/aes67_bridge_xilinx/csr.csv
```

### 2. Gateware

```sh
source /tools/Xilinx/Vivado/2024.2/settings64.sh
cd FPGA/boards/xilinx/alibaba_ku3p
vivado -mode batch -source build.tcl -tclargs -project    # IP generation only, fails fast
```

Expected first-run fixes, in order of likelihood:

1. `set_property` complains about an XDMA/PCS property name: run
   `report_property [get_ips xdma_0]` in the created project and adjust
   `build.tcl`.
2. Synthesis reports a port mismatch on `xdma_inst` / `pcs_inst`: open the
   generated IP's instantiation template (`.vho`) and copy its port list into
   the component declaration in `top_alibaba_ku3p.vhd`.
3. DRC on bank 86/87 IO standards: switch all pins of the offending bank to
   the same standard (LVCMOS18 and LVCMOS33 must not be mixed).

Then the full build (30 to 60 min):

```sh
vivado -mode batch -source build.tcl
```

Check `build/timing_summary.rpt` for negative slack. Outputs
`build/aes67_ku3p.bit` and `build/aes67_ku3p.mcs`.

### 3. First contact over JTAG

```sh
vivado -mode batch -source program.tcl        # volatile bitstream
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -d 10ee:ae67 -vv                        # BAR0 4 MiB, LnkSta x4 5 GT/s, MSI
```

If the card does not enumerate: check the PERST pin (try T19), check
`user_lnk_up` on LED 0, try Gen1 / x1 in `build.tcl` for a first link, and
remember a cold boot with the bitstream in flash is the reliable path.

Ethernet sanity without the driver: LED 1 = PCS link status. If it stays off
with a fibre module, toggle autoneg (write 0x00 to `PCS_CTRL`, BAR0+0x200018)
or try the SGMII variant of the IP for copper modules.

### 4. Driver

```sh
cd driver/aes67_eth && make && sudo insmod aes67_eth_drv.ko
dmesg | tail                    # "AES67 PCIe card, gateware 1.0, IRQ n (MSI)", ALSA card line
ip link                         # new interface; bring it up, DHCP or static
ethtool -T <if>                 # HW timestamps + PHC index
sudo ptp4l -H -i <if> -m        # offsets should converge to < 1 us
aplay -l
```

Register poke path for debugging: `aes67cfg peek/poke` through
`/dev/aes67ctl`, or `devmem`-style access to BAR0 via `/sys/bus/pci/devices/.../resource0`.

### 5. Audio

```sh
speaker-test -D hw:AES67 -c 32 -r 48000 -F S32_LE -t sine
arecord -D hw:AES67 -f S32_LE -r 48000 -c 32 -d 5 cap.wav
```

Watch `BAR0+0x100024` / `0x100044` (underrun / overrun counters) and the
`STATUS` sticky bits. Configure the RTP streams with `aes67cfg` as on the Pi;
playback channel n is AES67 TX channel n, capture channel n is RX channel n.

### 6. Persist

```sh
vivado -mode batch -source program.tcl -tclargs -flash    # QSPI, then power-cycle
```

Add `aes67_eth_drv` to `/etc/modules-load.d/` (see `driver/aes67_eth/Makefile install`, minus the Pi overlay).

## Open items / later

- More sample rates (44.1/96 kHz): needs the media clock generics and the ALSA
  `rates` mask.
- The eth_buf control-plane path uses one MMIO read per byte (~1.5 ms per full
  frame). Fine for PTP/SAP/mDNS; a DMA path could come later.
- Second SFP cage unused (could be a redundant AES67 leg).
- On-card metering is disabled (`ENABLE_METERING => false`); enable when the
  LiteX CSRs for it are wanted on the host.
- The XDMA AXI-Bridge mode was chosen so the FPGA masters host memory like a
  classic sound card; if the bridge's S_AXIB translation is awkward in the
  installed IP version, the alternative is XDMA DMA mode with its descriptor
  engines and a rewrite of `pcie_audio_dma`/`aes67_pcm.c`.
