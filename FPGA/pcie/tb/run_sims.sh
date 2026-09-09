#!/bin/bash
# Analyse the whole VHDL tree and run the PCIe block testbenches with GHDL.
#   FPGA/pcie/tb/run_sims.sh [path/to/ghdl]
# Needs GHDL >= 4 (VHDL-2008); the mcode release tarball from
# https://github.com/ghdl/ghdl/releases works without installation.
set -e
G=${1:-ghdl}
R=$(cd "$(dirname "$0")/../.." && pwd)
M=$R/FPGA_Ethernet/FPGA/ethernet_mac; E=$R/FPGA_Ethernet/FPGA
W=$(mktemp -d)
cd "$W"
FILES="$M/miim_types.vhd $M/ethernet_types.vhd $M/utility.vhd $M/intel/utility.vhd $M/framing_common.vhd
$M/crc.vhd $M/crc32.vhd $M/single_signal_synchronizer.vhd $M/intel/single_signal_synchronizer.vhd
$M/reset_generator.vhd $M/mii_gmii_io.vhd $M/intel/mii_gmii_io.vhd $M/mii_gmii.vhd $M/miim_registers.vhd
$M/miim_control.vhd $M/miim.vhd $M/framing.vhd $M/ethernet.vhd $E/const_eth_config.vhd
$E/detect_rising_edge.vhd $E/ethernet_control.vhd $E/ethernet_packet_parser.vhd $E/ethernet_receive.vhd
$E/ethernet_reset.vhd $E/eth_ram.vhd $E/reverse_mac.vhd $R/packages/audioclks_pkg.vhd
$R/packages/wallclock_signals_pkg.vhd $R/packages/system_cfg_pkg.vhd
$(ls $R/ptp/*.vhd | grep -v _tb) $(ls $R/audio_rx/*.vhd $R/audio_tx/*.vhd | grep -v _tb)
$R/audioclock_generator_sysclk.vhd $R/clock_ppb_meter.vhd $R/ethernet_packet_aggregator.vhd
$R/ethernet_timestamp_mii.vhd $R/eth_tx_arbiter.vhd $R/ethernet_top.vhd $R/litex_eth_buffer_bridge.vhd
$R/mii_converters.vhd $R/sysclk_pll_gen.vhd $R/aes67_top.vhd $R/aes67_wb_bridge.vhd $R/wb_bridge_top.vhd
$R/pcie/async_fifo.vhd $R/pcie/pcie_axi_slave.vhd $R/pcie/simplebus_wb_master.vhd $R/pcie/pcie_sb_decoder.vhd
$R/pcie/pcie_ctrl_regs.vhd $R/pcie/pcie_audio_dma.vhd $R/boards/xilinx/alibaba_ku3p/top_alibaba_ku3p.vhd
$R/pcie/tb/tb_pcie_regs.vhd $R/pcie/tb/tb_pcie_audio_dma.vhd"
OPTS="--std=08 -frelaxed --warn-no-hide --warn-no-others"
# a few passes resolve the analysis order of entities instantiated by name
PENDING="$FILES"
for pass in 1 2 3 4 5; do
  NEXT=""
  for f in $PENDING; do $G -a $OPTS "$f" 2>/dev/null || NEXT="$NEXT $f"; done
  PENDING="$NEXT"; [ -z "$PENDING" ] && break
done
if [ -n "$PENDING" ]; then echo "analysis failed:"; for f in $PENDING; do $G -a $OPTS "$f"; done; exit 1; fi
$G -e $OPTS --warn-no-binding top_alibaba_ku3p
echo "== tb_pcie_regs"
$G -e $OPTS tb_pcie_regs && $G -r $OPTS tb_pcie_regs --assert-level=none 2>&1 | grep -E "FAIL|PASSED|FAILED"
for ch in 8 16 32; do
  echo "== tb_pcie_audio_dma CH=$ch"
  $G -e $OPTS tb_pcie_audio_dma && $G -r $OPTS tb_pcie_audio_dma --assert-level=none -gCH=$ch 2>&1 | grep -E "FAIL|PASSED|FAILED"
done
rm -rf "$W"
