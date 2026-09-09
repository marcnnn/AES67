# Alibaba Cloud AS02MC04 accelerator card (R1291-F9003-02)
# Xilinx Kintex UltraScale+ XCKU3P-FFVB676-1E (some cards are -2E)
#
# Pin data collected from the community reverse-engineering notes:
#   https://github.com/dkozel/Alibaba-Cloud-FPGA
#   https://gist.github.com/Chester-Gillon/765d6286b1c34c7dc26a7b4c4dd0c48c
#   https://essenceia.github.io/projects/alibaba_cloud_fpga/
# The card has no official documentation. Everything below has been reported
# working by at least one of those sources unless marked otherwise.

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
# 100 MHz LVDS oscillator, bank 67 (system clock for the AES67 data plane)
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVDS} [get_ports clk100_p]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS} [get_ports clk100_n]
create_clock -period 10.000 -name clk100 [get_ports clk100_p]

# PCIe reference clock, 100 MHz from the slot (MGTREFCLK0 of quad 225)
set_property PACKAGE_PIN T7 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN T6 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# SFP reference clock, 156.25 MHz (MGTREFCLK0 of quad 227)
set_property PACKAGE_PIN K7 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN K6 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# ---------------------------------------------------------------------------
# PCIe (Gen3 x8 electrically; the board's lane order is reversed and most
# hosts train x4, see the notes). PCIE4 block X0Y0 on GTY quads 224/225.
# PERST comes in on A9 (bank 86). One source reports T19 instead; if the
# link never trains, try that pin.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS18 PULLUP true} [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

set_property PACKAGE_PIN AF2 [get_ports {pcie_rx_p[0]}]
set_property PACKAGE_PIN AE4 [get_ports {pcie_rx_p[1]}]
set_property PACKAGE_PIN AD2 [get_ports {pcie_rx_p[2]}]
set_property PACKAGE_PIN AB2 [get_ports {pcie_rx_p[3]}]
set_property PACKAGE_PIN Y2  [get_ports {pcie_rx_p[4]}]
set_property PACKAGE_PIN V2  [get_ports {pcie_rx_p[5]}]
set_property PACKAGE_PIN T2  [get_ports {pcie_rx_p[6]}]
set_property PACKAGE_PIN P2  [get_ports {pcie_rx_p[7]}]
# The TX pins are implied by the GTY channel each RX pin belongs to; Vivado
# derives them together with the *_n partners from the package pin table.

# ---------------------------------------------------------------------------
# SFP cage 1 (GTY quad 227) - the AES67 network port
# ---------------------------------------------------------------------------
# Reported pairs: TX B6/B7, RX A3/A4. Xilinx numbers the N pin of a GT pair
# one below the P pin, hence the assignment below.
set_property PACKAGE_PIN B7 [get_ports sfp_tx_p]
set_property PACKAGE_PIN B6 [get_ports sfp_tx_n]
set_property PACKAGE_PIN A4 [get_ports sfp_rx_p]
set_property PACKAGE_PIN A3 [get_ports sfp_rx_n]

# Control lines, bank 87 (LVCMOS18 per the reports; the bank VCCO may
# actually be 3.3 V, which still works for these inputs/outputs).
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sfp_mod_abs]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sfp_tx_fault]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sfp_los]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sfp_i2c_sda]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sfp_i2c_scl]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS18} [get_ports sfp_led]
set_false_path -from [get_ports {sfp_mod_abs sfp_tx_fault sfp_los}]
set_false_path -to   [get_ports {sfp_led sfp_i2c_sda sfp_i2c_scl}]

# ---------------------------------------------------------------------------
# LEDs (bank 86/87)
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS18} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS18} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS18} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS18} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS18} [get_ports led_r]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS18} [get_ports led_g]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS18} [get_ports led_heart]
set_false_path -to [get_ports {led[*] led_r led_g led_heart}]

# Reset push button (active low)
set_property -dict {PACKAGE_PIN F12 IOSTANDARD LVCMOS18 PULLUP true} [get_ports sw_reset_n]
set_false_path -from [get_ports sw_reset_n]

# ---------------------------------------------------------------------------
# Clock domain relationships
# ---------------------------------------------------------------------------
# The design has four independent clock families:
#   * clk100 -> MMCM (sys 125 MHz, mcu 75 MHz)      AES67 data plane
#   * pcie_refclk -> PCIe user clock (axi_aclk)      PCIe bridge, DMA, regs
#   * sfp_refclk -> PCS/PMA userclk2 (125 MHz)       GMII / MAC
#   * clk100 straight through BUFG                   PCS DRP / independent clk
# All crossings are handled with synchronisers, toggle handshakes and the
# async FIFO (FPGA/pcie/), so declare them asynchronous to each other.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk100] \
    -group [get_clocks -include_generated_clocks pcie_refclk] \
    -group [get_clocks -include_generated_clocks sfp_refclk]

# ---------------------------------------------------------------------------
# Configuration: QSPI flash MT25QU256 (x4), 1.8 V, for a persistent bitstream
# ---------------------------------------------------------------------------
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN disable [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
