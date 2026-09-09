-- Board top for the Alibaba Cloud AS02MC04 accelerator card
-- (Kintex UltraScale+ XCKU3P-FFVB676) as a PCIe AES67 sound card.
--
--                 +---------------------------------------------------+
--   SFP28 cage 1  |  PCS/PMA (1000BASE-X) --GMII--> wb_bridge_top     |
--   (GTY 227)  <->|                                (AES67 data plane, |
--                 |                                 LiteX aes67_bridge)|
--                 |                                     ^  aes67_wb    |
--   PCIe x4    <->|  XDMA (AXI bridge) --M_AXIB--> pcie_axi_slave ----+|
--   (GTY 224/225) |        ^                       |  BAR0 decoder     |
--                 |        | S_AXIB                +-> audio DMA regs  |
--                 |        |                       +-> ctrl/IRQ regs   |
--                 |   pcie_audio_dma <== parallel sample registers ==> |
--                 +---------------------------------------------------+
--
-- Control plane = the Linux host (driver/aes67_eth, PCI variant): it owns the
-- Wishbone bus through BAR0, runs ptp4l on the FPGA wallclock (software PTP:
-- the gateware only timestamps) and exposes the sample registers as an ALSA
-- card through the bus-mastering DMA engine.
--
-- Clocking
--   clk100 (LVDS osc)  -> MMCM in sysclk_pll_gen: 125 MHz data plane, 75 MHz
--                         LiteX bridge clock. Also the PCS "independent" clock.
--   sfp_refclk 156.25  -> PCS/PMA GTY; userclk2_out (125 MHz) clocks GMII/MAC.
--   pcie_refclk 100    -> PCIe hard block; axi_aclk clocks everything PCIe.
--
-- Vendor primitives and the two Xilinx IP cores are instantiated through
-- local component declarations so the file analyses without unisim; the
-- build script (build.tcl) generates the IPs with the matching parameters.
-- If the installed IP version exposes a different port list, adapt the two
-- component declarations below from the IP's instantiation template.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.system_cfg_pkg.all;
use work.audioclks_pkg.all;

entity top_alibaba_ku3p is
    generic (
        syscfg         : t_global_system_cfg := global_system_cfg_alibaba_ku3p;
        PCIE_LANES     : positive := 4;
        AXI_DATA_WIDTH : positive := 128;   -- must match the XDMA configuration
        AXI_ADDR_WIDTH : positive := 64;
        GW_VERSION     : std_logic_vector(31 downto 0) := x"00010000";
        LED_ACTIVE_LOW : boolean := true
    );
    port (
        -- 100 MHz LVDS oscillator
        clk100_p      : in  std_logic;
        clk100_n      : in  std_logic;
        sw_reset_n    : in  std_logic;

        -- PCIe
        pcie_refclk_p : in  std_logic;
        pcie_refclk_n : in  std_logic;
        pcie_perst_n  : in  std_logic;
        pcie_rx_p     : in  std_logic_vector(PCIE_LANES - 1 downto 0);
        pcie_rx_n     : in  std_logic_vector(PCIE_LANES - 1 downto 0);
        pcie_tx_p     : out std_logic_vector(PCIE_LANES - 1 downto 0);
        pcie_tx_n     : out std_logic_vector(PCIE_LANES - 1 downto 0);

        -- SFP cage 1
        sfp_refclk_p  : in  std_logic;
        sfp_refclk_n  : in  std_logic;
        sfp_tx_p      : out std_logic;
        sfp_tx_n      : out std_logic;
        sfp_rx_p      : in  std_logic;
        sfp_rx_n      : in  std_logic;
        sfp_mod_abs   : in  std_logic;
        sfp_tx_fault  : in  std_logic;
        sfp_los       : in  std_logic;
        sfp_led       : out std_logic;
        sfp_i2c_sda   : inout std_logic;
        sfp_i2c_scl   : inout std_logic;

        -- LEDs
        led           : out std_logic_vector(3 downto 0);
        led_r         : out std_logic;
        led_g         : out std_logic;
        led_heart     : out std_logic
    );
end entity;

architecture rtl of top_alibaba_ku3p is
    ------------------------------------------------------------------
    -- Xilinx primitives (bound to unisim by name in Vivado)
    ------------------------------------------------------------------
    component IBUFDS
        port (O : out std_logic; I : in std_logic; IB : in std_logic);
    end component;
    component BUFG
        port (O : out std_logic; I : in std_logic);
    end component;
    component IBUFDS_GTE4
        generic (
            REFCLK_EN_TX_PATH  : bit := '0';
            REFCLK_HROW_CK_SEL : bit_vector := "00";
            REFCLK_ICNTL_RX    : bit_vector := "00");
        port (
            O     : out std_logic;
            ODIV2 : out std_logic;
            CEB   : in  std_logic;
            I     : in  std_logic;
            IB    : in  std_logic);
    end component;
    component BUFG_GT
        port (
            O       : out std_logic;
            CE      : in  std_logic;
            CEMASK  : in  std_logic;
            CLR     : in  std_logic;
            CLRMASK : in  std_logic;
            DIV     : in  std_logic_vector(2 downto 0);
            I       : in  std_logic);
    end component;

    ------------------------------------------------------------------
    -- Xilinx 1G/2.5G Ethernet PCS/PMA (1000BASE-X, GTY, shared logic in
    -- core, MDIO enabled). Port list per PG047 v16.x.
    ------------------------------------------------------------------
    component gig_eth_pcs_pma_0
        port (
            gtrefclk_p             : in  std_logic;
            gtrefclk_n             : in  std_logic;
            gtrefclk_out           : out std_logic;
            gtrefclk_bufg_out      : out std_logic;
            txp                    : out std_logic;
            txn                    : out std_logic;
            rxp                    : in  std_logic;
            rxn                    : in  std_logic;
            independent_clock_bufg : in  std_logic;
            userclk_out            : out std_logic;
            userclk2_out           : out std_logic;
            rxuserclk_out          : out std_logic;
            rxuserclk2_out         : out std_logic;
            resetdone              : out std_logic;
            pma_reset_out          : out std_logic;
            mmcm_locked_out        : out std_logic;
            gmii_txd               : in  std_logic_vector(7 downto 0);
            gmii_tx_en             : in  std_logic;
            gmii_tx_er             : in  std_logic;
            gmii_rxd               : out std_logic_vector(7 downto 0);
            gmii_rx_dv             : out std_logic;
            gmii_rx_er             : out std_logic;
            gmii_isolate           : out std_logic;
            mdc                    : in  std_logic;
            mdio_i                 : in  std_logic;
            mdio_o                 : out std_logic;
            mdio_t                 : out std_logic;
            phyaddr                : in  std_logic_vector(4 downto 0);
            configuration_vector   : in  std_logic_vector(4 downto 0);
            configuration_valid    : in  std_logic;
            an_interrupt           : out std_logic;
            an_adv_config_vector   : in  std_logic_vector(15 downto 0);
            an_adv_config_val      : in  std_logic;
            an_restart_config      : in  std_logic;
            status_vector          : out std_logic_vector(15 downto 0);
            reset                  : in  std_logic;
            signal_detect          : in  std_logic;
            gtpowergood            : out std_logic);
    end component;

    ------------------------------------------------------------------
    -- XDMA / AXI Bridge Subsystem for PCIe (functional mode "AXI Bridge",
    -- Gen2 x4, 128-bit AXI at 125 MHz, one user interrupt). Port list per
    -- PG194; BAR0 (4 MiB) -> M_AXIB at AXI address 0, S_AXIB -> host memory
    -- with an identity AXI-to-PCIe translation.
    ------------------------------------------------------------------
    component xdma_0
        port (
            sys_clk          : in  std_logic;
            sys_clk_gt       : in  std_logic;
            sys_rst_n        : in  std_logic;
            user_lnk_up      : out std_logic;
            pci_exp_txp      : out std_logic_vector(PCIE_LANES - 1 downto 0);
            pci_exp_txn      : out std_logic_vector(PCIE_LANES - 1 downto 0);
            pci_exp_rxp      : in  std_logic_vector(PCIE_LANES - 1 downto 0);
            pci_exp_rxn      : in  std_logic_vector(PCIE_LANES - 1 downto 0);
            axi_aclk         : out std_logic;
            axi_aresetn      : out std_logic;
            usr_irq_req      : in  std_logic_vector(0 downto 0);
            usr_irq_ack      : out std_logic_vector(0 downto 0);
            msi_enable       : out std_logic;
            msi_vector_width : out std_logic_vector(2 downto 0);
            interrupt_out    : out std_logic;
            -- M_AXIB: host -> FPGA (BAR0)
            m_axib_awid      : out std_logic_vector(3 downto 0);
            m_axib_awaddr    : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
            m_axib_awlen     : out std_logic_vector(7 downto 0);
            m_axib_awsize    : out std_logic_vector(2 downto 0);
            m_axib_awburst   : out std_logic_vector(1 downto 0);
            m_axib_awprot    : out std_logic_vector(2 downto 0);
            m_axib_awvalid   : out std_logic;
            m_axib_awready   : in  std_logic;
            m_axib_awlock    : out std_logic;
            m_axib_awcache   : out std_logic_vector(3 downto 0);
            m_axib_wdata     : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
            m_axib_wstrb     : out std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
            m_axib_wlast     : out std_logic;
            m_axib_wvalid    : out std_logic;
            m_axib_wready    : in  std_logic;
            m_axib_bid       : in  std_logic_vector(3 downto 0);
            m_axib_bresp     : in  std_logic_vector(1 downto 0);
            m_axib_bvalid    : in  std_logic;
            m_axib_bready    : out std_logic;
            m_axib_arid      : out std_logic_vector(3 downto 0);
            m_axib_araddr    : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
            m_axib_arlen     : out std_logic_vector(7 downto 0);
            m_axib_arsize    : out std_logic_vector(2 downto 0);
            m_axib_arburst   : out std_logic_vector(1 downto 0);
            m_axib_arprot    : out std_logic_vector(2 downto 0);
            m_axib_arvalid   : out std_logic;
            m_axib_arready   : in  std_logic;
            m_axib_arlock    : out std_logic;
            m_axib_arcache   : out std_logic_vector(3 downto 0);
            m_axib_rid       : in  std_logic_vector(3 downto 0);
            m_axib_rdata     : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
            m_axib_rresp     : in  std_logic_vector(1 downto 0);
            m_axib_rlast     : in  std_logic;
            m_axib_rvalid    : in  std_logic;
            m_axib_rready    : out std_logic;
            -- S_AXIB: FPGA -> host memory (bus mastering)
            s_axib_awid      : in  std_logic_vector(3 downto 0);
            s_axib_awaddr    : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
            s_axib_awregion  : in  std_logic_vector(3 downto 0);
            s_axib_awlen     : in  std_logic_vector(7 downto 0);
            s_axib_awsize    : in  std_logic_vector(2 downto 0);
            s_axib_awburst   : in  std_logic_vector(1 downto 0);
            s_axib_awvalid   : in  std_logic;
            s_axib_awready   : out std_logic;
            s_axib_wdata     : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
            s_axib_wstrb     : in  std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
            s_axib_wlast     : in  std_logic;
            s_axib_wvalid    : in  std_logic;
            s_axib_wready    : out std_logic;
            s_axib_bid       : out std_logic_vector(3 downto 0);
            s_axib_bresp     : out std_logic_vector(1 downto 0);
            s_axib_bvalid    : out std_logic;
            s_axib_bready    : in  std_logic;
            s_axib_arid      : in  std_logic_vector(3 downto 0);
            s_axib_araddr    : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
            s_axib_arregion  : in  std_logic_vector(3 downto 0);
            s_axib_arlen     : in  std_logic_vector(7 downto 0);
            s_axib_arsize    : in  std_logic_vector(2 downto 0);
            s_axib_arburst   : in  std_logic_vector(1 downto 0);
            s_axib_arvalid   : in  std_logic;
            s_axib_arready   : out std_logic;
            s_axib_rid       : out std_logic_vector(3 downto 0);
            s_axib_rdata     : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
            s_axib_rresp     : out std_logic_vector(1 downto 0);
            s_axib_rlast     : out std_logic;
            s_axib_rvalid    : out std_logic;
            s_axib_rready    : in  std_logic);
    end component;

    constant SAMPLE_BITS : natural := syscfg.AUDIO_CONFIG.PARALLEL_BYTE_DEPTH * 8;
    constant PB_CH  : natural := syscfg.AUDIO_CONFIG.TX_AD_CFG.CHANNELS;   -- host -> network
    constant CAP_CH : natural := syscfg.AUDIO_CONFIG.RX_DA_CFG.CHANNELS;   -- network -> host

    ------------------------------------------------------------------
    -- clocks / resets
    ------------------------------------------------------------------
    signal clk100_ibuf, clk100 : std_logic;
    signal sys_clk, mcu_clk : std_logic;
    signal rst_n : std_logic;

    signal pcie_sys_clk_gt, pcie_sys_clk_odiv2, pcie_sys_clk : std_logic;
    signal axi_clk, axi_rst_n : std_logic;
    signal user_lnk_up : std_logic;

    ------------------------------------------------------------------
    -- Ethernet PCS <-> MAC
    ------------------------------------------------------------------
    signal pcs_userclk2 : std_logic;
    signal gmii_txd, gmii_rxd : std_logic_vector(7 downto 0);
    signal gmii_tx_en, gmii_rx_dv, gmii_rx_er : std_logic;
    signal mdc : std_logic;
    signal mdio_wire : std_logic;
    signal mdio_o, mdio_t : std_logic;
    signal pcs_status : std_logic_vector(15 downto 0);
    signal pcs_resetdone, pcs_mmcm_locked, pcs_an_interrupt : std_logic;
    signal pcs_cfg_vector : std_logic_vector(4 downto 0);
    signal pcs_an_restart, pcs_reset_req, pcs_reset : std_logic;
    signal pcs_cfg_valid : std_logic := '0';
    signal pcs_cfg_timer : unsigned(7 downto 0) := (others => '0');
    signal sfp_tx_disable : std_logic;
    signal sfp_signal_detect : std_logic;

    ------------------------------------------------------------------
    -- Wishbone (mcu_clk domain)
    ------------------------------------------------------------------
    signal wb_adr   : std_logic_vector(29 downto 0);
    signal wb_dat_w, wb_dat_r : std_logic_vector(31 downto 0);
    signal wb_sel   : std_logic_vector(3 downto 0);
    signal wb_cyc, wb_stb, wb_we, wb_ack, wb_err : std_logic;
    signal wb_cti   : std_logic_vector(2 downto 0);
    signal wb_bte   : std_logic_vector(1 downto 0);
    signal eth_buf_irq : std_logic;

    ------------------------------------------------------------------
    -- audio
    ------------------------------------------------------------------
    signal audioclocks : t_audio_clocks;
    signal pb_samples  : std_logic_vector(SAMPLE_BITS * PB_CH - 1 downto 0);
    signal cap_samples : std_logic_vector(SAMPLE_BITS * CAP_CH - 1 downto 0);

    ------------------------------------------------------------------
    -- M_AXIB (host -> FPGA)
    ------------------------------------------------------------------
    signal m_awid, m_arid, m_bid, m_rid : std_logic_vector(3 downto 0);
    signal m_awaddr, m_araddr : std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    signal m_awlen, m_arlen : std_logic_vector(7 downto 0);
    signal m_awsize, m_arsize : std_logic_vector(2 downto 0);
    signal m_awburst, m_arburst, m_bresp, m_rresp : std_logic_vector(1 downto 0);
    signal m_awvalid, m_awready, m_wlast, m_wvalid, m_wready : std_logic;
    signal m_bvalid, m_bready, m_arvalid, m_arready : std_logic;
    signal m_rlast, m_rvalid, m_rready : std_logic;
    signal m_wdata, m_rdata : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    signal m_wstrb : std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);

    ------------------------------------------------------------------
    -- S_AXIB (FPGA -> host)
    ------------------------------------------------------------------
    signal s_awid, s_arid, s_bid, s_rid : std_logic_vector(3 downto 0);
    signal s_awaddr, s_araddr : std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    signal s_awlen, s_arlen : std_logic_vector(7 downto 0);
    signal s_awsize, s_arsize : std_logic_vector(2 downto 0);
    signal s_awburst, s_arburst, s_bresp, s_rresp : std_logic_vector(1 downto 0);
    signal s_awvalid, s_awready, s_wlast, s_wvalid, s_wready : std_logic;
    signal s_bvalid, s_bready, s_arvalid, s_arready : std_logic;
    signal s_rlast, s_rvalid, s_rready : std_logic;
    signal s_wdata, s_rdata : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    signal s_wstrb : std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);

    ------------------------------------------------------------------
    -- simple bus
    ------------------------------------------------------------------
    signal sb_addr  : std_logic_vector(21 downto 0);
    signal sb_wdata, sb_rdata : std_logic_vector(31 downto 0);
    signal sb_wstrb : std_logic_vector(3 downto 0);
    signal sb_we, sb_req, sb_ack, sb_err : std_logic;
    signal wbm_req, wbm_ack, wbm_err : std_logic;
    signal wbm_rdata : std_logic_vector(31 downto 0);
    signal dma_req, dma_ack : std_logic;
    signal dma_rdata : std_logic_vector(31 downto 0);
    signal ctl_req, ctl_ack : std_logic;
    signal ctl_rdata : std_logic_vector(31 downto 0);

    ------------------------------------------------------------------
    -- interrupts / LEDs
    ------------------------------------------------------------------
    signal irq_pb_period, irq_cap_period, irq_pb_underrun, irq_cap_overrun : std_logic;
    signal usr_irq_req, usr_irq_ack : std_logic_vector(0 downto 0);
    signal ctrl_leds : std_logic_vector(7 downto 0);
    signal heartbeat_cnt : unsigned(26 downto 0) := (others => '0');
    signal leds_raw : std_logic_vector(6 downto 0);
    signal sfp_led_raw : std_logic;
begin
    ------------------------------------------------------------------
    -- system clock and reset
    ------------------------------------------------------------------
    clk100_ibufds : IBUFDS port map (O => clk100_ibuf, I => clk100_p, IB => clk100_n);
    clk100_bufg   : BUFG   port map (O => clk100, I => clk100_ibuf);
    rst_n <= sw_reset_n;

    ------------------------------------------------------------------
    -- AES67 data plane + LiteX bridge (CPU-less wrapper)
    ------------------------------------------------------------------
    wb_bridge_top_inst : entity work.wb_bridge_top
        generic map (syscfg => syscfg)
        port map (
            rst_n_i               => rst_n,
            clock_i               => clk100,
            phy_refclk_i          => '0',
            phy_mii_enet_rx_clk   => pcs_userclk2,
            phy_mii_enet_rx_dv    => gmii_rx_dv,
            phy_mii_enet_resetn   => open,
            phy_mii_enet_rx_d     => gmii_rxd,
            phy_mii_enet_tx_clk   => open,
            phy_mii_enet_tx_clk_i => pcs_userclk2,
            phy_mii_enet_tx_en    => gmii_tx_en,
            phy_mii_enet_tx_d     => gmii_txd,
            enet_mdc              => mdc,
            enet_mdio             => mdio_wire,
            pll_512fs_i           => '0',
            audioclocks_o         => audioclocks,
            selected_audio_clock_o => open,
            tdm_in                => (others => '0'),
            tdm_out               => open,
            rx_sample_register    => cap_samples,
            tx_sample_register    => pb_samples,
            mcu_clk_o             => mcu_clk,
            mcu_clk_90_o          => open,
            sys_clk_o             => sys_clk,
            mcu_irq_o             => eth_buf_irq,
            aes67_wb_ack          => wb_ack,
            aes67_wb_adr          => wb_adr,
            aes67_wb_bte          => wb_bte,
            aes67_wb_cti          => wb_cti,
            aes67_wb_cyc          => wb_cyc,
            aes67_wb_dat_r        => wb_dat_r,
            aes67_wb_dat_w        => wb_dat_w,
            aes67_wb_err          => wb_err,
            aes67_wb_sel          => wb_sel,
            aes67_wb_stb          => wb_stb,
            aes67_wb_we           => wb_we,
            dbg_mac_tx_clk_o      => open);

    ------------------------------------------------------------------
    -- SFP: 1000BASE-X PCS/PMA on the GTY, GMII to the MAC
    ------------------------------------------------------------------
    -- MDIO: the MAC drives the wire (or releases it) through an inout; the
    -- PCS core has split i/o/t pins. Vivado turns this internal tri-state
    -- net into a mux; both ends release the wire outside their own bit
    -- slots, so no pull-up is modelled (the PCS ignores anything that is
    -- not a proper 32-bit preamble).
    mdio_wire <= mdio_o when mdio_t = '0' else 'Z';
    sfp_signal_detect <= (not sfp_los) and (not sfp_mod_abs);
    pcs_reset <= (not rst_n) or pcs_reset_req;

    -- load configuration_vector / advertisement once the core is out of reset
    p_pcs_cfg : process(clk100)
    begin
        if rising_edge(clk100) then
            pcs_cfg_valid <= '0';
            if pcs_resetdone = '0' then
                pcs_cfg_timer <= (others => '0');
            elsif pcs_cfg_timer /= x"FF" then
                pcs_cfg_timer <= pcs_cfg_timer + 1;
                if pcs_cfg_timer = x"80" then
                    pcs_cfg_valid <= '1';
                end if;
            end if;
        end if;
    end process;

    pcs_inst : gig_eth_pcs_pma_0
        port map (
            gtrefclk_p             => sfp_refclk_p,
            gtrefclk_n             => sfp_refclk_n,
            gtrefclk_out           => open,
            gtrefclk_bufg_out      => open,
            txp                    => sfp_tx_p,
            txn                    => sfp_tx_n,
            rxp                    => sfp_rx_p,
            rxn                    => sfp_rx_n,
            independent_clock_bufg => clk100,
            userclk_out            => open,
            userclk2_out           => pcs_userclk2,
            rxuserclk_out          => open,
            rxuserclk2_out         => open,
            resetdone              => pcs_resetdone,
            pma_reset_out          => open,
            mmcm_locked_out        => pcs_mmcm_locked,
            gmii_txd               => gmii_txd,
            gmii_tx_en             => gmii_tx_en,
            gmii_tx_er             => '0',
            gmii_rxd               => gmii_rxd,
            gmii_rx_dv             => gmii_rx_dv,
            gmii_rx_er             => gmii_rx_er,
            gmii_isolate           => open,
            mdc                    => mdc,
            mdio_i                 => to_X01(mdio_wire),
            mdio_o                 => mdio_o,
            mdio_t                 => mdio_t,
            phyaddr                => std_logic_vector(syscfg.PHY_CONFIG.MIIM_PHY_ADDRESS),
            configuration_vector   => pcs_cfg_vector,
            configuration_valid    => pcs_cfg_valid,
            an_interrupt           => pcs_an_interrupt,
            an_adv_config_vector   => x"0020",      -- full duplex, no pause
            an_adv_config_val      => pcs_cfg_valid,
            an_restart_config      => pcs_an_restart,
            status_vector          => pcs_status,
            reset                  => pcs_reset,
            signal_detect          => sfp_signal_detect,
            gtpowergood            => open);

    sfp_i2c_sda <= 'Z';
    sfp_i2c_scl <= 'Z';

    ------------------------------------------------------------------
    -- PCIe: reference clock, XDMA AXI bridge
    ------------------------------------------------------------------
    pcie_refclk_ibuf : IBUFDS_GTE4
        generic map (REFCLK_HROW_CK_SEL => "00")
        port map (O => pcie_sys_clk_gt, ODIV2 => pcie_sys_clk_odiv2, CEB => '0',
                  I => pcie_refclk_p, IB => pcie_refclk_n);
    pcie_sysclk_bufg : BUFG_GT
        port map (O => pcie_sys_clk, CE => '1', CEMASK => '1', CLR => '0', CLRMASK => '1',
                  DIV => "000", I => pcie_sys_clk_odiv2);

    xdma_inst : xdma_0
        port map (
            sys_clk          => pcie_sys_clk,
            sys_clk_gt       => pcie_sys_clk_gt,
            sys_rst_n        => pcie_perst_n,
            user_lnk_up      => user_lnk_up,
            pci_exp_txp      => pcie_tx_p,
            pci_exp_txn      => pcie_tx_n,
            pci_exp_rxp      => pcie_rx_p,
            pci_exp_rxn      => pcie_rx_n,
            axi_aclk         => axi_clk,
            axi_aresetn      => axi_rst_n,
            usr_irq_req      => usr_irq_req,
            usr_irq_ack      => usr_irq_ack,
            msi_enable       => open,
            msi_vector_width => open,
            interrupt_out    => open,
            m_axib_awid      => m_awid,
            m_axib_awaddr    => m_awaddr,
            m_axib_awlen     => m_awlen,
            m_axib_awsize    => m_awsize,
            m_axib_awburst   => m_awburst,
            m_axib_awprot    => open,
            m_axib_awvalid   => m_awvalid,
            m_axib_awready   => m_awready,
            m_axib_awlock    => open,
            m_axib_awcache   => open,
            m_axib_wdata     => m_wdata,
            m_axib_wstrb     => m_wstrb,
            m_axib_wlast     => m_wlast,
            m_axib_wvalid    => m_wvalid,
            m_axib_wready    => m_wready,
            m_axib_bid       => m_bid,
            m_axib_bresp     => m_bresp,
            m_axib_bvalid    => m_bvalid,
            m_axib_bready    => m_bready,
            m_axib_arid      => m_arid,
            m_axib_araddr    => m_araddr,
            m_axib_arlen     => m_arlen,
            m_axib_arsize    => m_arsize,
            m_axib_arburst   => m_arburst,
            m_axib_arprot    => open,
            m_axib_arvalid   => m_arvalid,
            m_axib_arready   => m_arready,
            m_axib_arlock    => open,
            m_axib_arcache   => open,
            m_axib_rid       => m_rid,
            m_axib_rdata     => m_rdata,
            m_axib_rresp     => m_rresp,
            m_axib_rlast     => m_rlast,
            m_axib_rvalid    => m_rvalid,
            m_axib_rready    => m_rready,
            s_axib_awid      => s_awid,
            s_axib_awaddr    => s_awaddr,
            s_axib_awregion  => "0000",
            s_axib_awlen     => s_awlen,
            s_axib_awsize    => s_awsize,
            s_axib_awburst   => s_awburst,
            s_axib_awvalid   => s_awvalid,
            s_axib_awready   => s_awready,
            s_axib_wdata     => s_wdata,
            s_axib_wstrb     => s_wstrb,
            s_axib_wlast     => s_wlast,
            s_axib_wvalid    => s_wvalid,
            s_axib_wready    => s_wready,
            s_axib_bid       => s_bid,
            s_axib_bresp     => s_bresp,
            s_axib_bvalid    => s_bvalid,
            s_axib_bready    => s_bready,
            s_axib_arid      => s_arid,
            s_axib_araddr    => s_araddr,
            s_axib_arregion  => "0000",
            s_axib_arlen     => s_arlen,
            s_axib_arsize    => s_arsize,
            s_axib_arburst   => s_arburst,
            s_axib_arvalid   => s_arvalid,
            s_axib_arready   => s_arready,
            s_axib_rid       => s_rid,
            s_axib_rdata     => s_rdata,
            s_axib_rresp     => s_rresp,
            s_axib_rlast     => s_rlast,
            s_axib_rvalid    => s_rvalid,
            s_axib_rready    => s_rready);

    ------------------------------------------------------------------
    -- BAR0: AXI slave -> simple bus -> {Wishbone, DMA regs, ctrl regs}
    ------------------------------------------------------------------
    axi_slave_inst : entity work.pcie_axi_slave
        generic map (
            AXI_ID_WIDTH => 4, AXI_ADDR_WIDTH => AXI_ADDR_WIDTH,
            AXI_DATA_WIDTH => AXI_DATA_WIDTH, SB_ADDR_WIDTH => 22)
        port map (
            clk => axi_clk, rst_n => axi_rst_n,
            s_axi_awid => m_awid, s_axi_awaddr => m_awaddr, s_axi_awlen => m_awlen,
            s_axi_awsize => m_awsize, s_axi_awburst => m_awburst,
            s_axi_awvalid => m_awvalid, s_axi_awready => m_awready,
            s_axi_wdata => m_wdata, s_axi_wstrb => m_wstrb, s_axi_wlast => m_wlast,
            s_axi_wvalid => m_wvalid, s_axi_wready => m_wready,
            s_axi_bid => m_bid, s_axi_bresp => m_bresp, s_axi_bvalid => m_bvalid, s_axi_bready => m_bready,
            s_axi_arid => m_arid, s_axi_araddr => m_araddr, s_axi_arlen => m_arlen,
            s_axi_arsize => m_arsize, s_axi_arburst => m_arburst,
            s_axi_arvalid => m_arvalid, s_axi_arready => m_arready,
            s_axi_rid => m_rid, s_axi_rdata => m_rdata, s_axi_rresp => m_rresp,
            s_axi_rlast => m_rlast, s_axi_rvalid => m_rvalid, s_axi_rready => m_rready,
            sb_addr => sb_addr, sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
            sb_req => sb_req, sb_ack => sb_ack, sb_rdata => sb_rdata, sb_err => sb_err);

    decoder_inst : entity work.pcie_sb_decoder
        port map (
            sb_addr => sb_addr, sb_req => sb_req, sb_ack => sb_ack, sb_rdata => sb_rdata, sb_err => sb_err,
            wb_req => wbm_req, wb_ack => wbm_ack, wb_rdata => wbm_rdata, wb_err => wbm_err,
            dma_req => dma_req, dma_ack => dma_ack, dma_rdata => dma_rdata,
            ctl_req => ctl_req, ctl_ack => ctl_ack, ctl_rdata => ctl_rdata);

    wb_master_inst : entity work.simplebus_wb_master
        generic map (WB_BASE => x"90000000", SB_ADDR_WIDTH => 22)
        port map (
            sb_clk => axi_clk, sb_rst_n => axi_rst_n,
            sb_addr => sb_addr, sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
            sb_req => wbm_req, sb_ack => wbm_ack, sb_rdata => wbm_rdata, sb_err => wbm_err,
            wb_clk => mcu_clk, wb_rst_n => rst_n,
            wb_adr => wb_adr, wb_dat_w => wb_dat_w, wb_dat_r => wb_dat_r, wb_sel => wb_sel,
            wb_cyc => wb_cyc, wb_stb => wb_stb, wb_we => wb_we, wb_ack => wb_ack, wb_err => wb_err,
            wb_cti => wb_cti, wb_bte => wb_bte);

    audio_dma_inst : entity work.pcie_audio_dma
        generic map (
            AXI_ID_WIDTH => 4, AXI_ADDR_WIDTH => AXI_ADDR_WIDTH, AXI_DATA_WIDTH => AXI_DATA_WIDTH,
            PB_CHANNELS => PB_CH, CAP_CHANNELS => CAP_CH, SAMPLE_BITS => SAMPLE_BITS,
            FIFO_DEPTH_BITS => 6)
        port map (
            axi_clk => axi_clk, axi_rst_n => axi_rst_n,
            m_axi_awid => s_awid, m_axi_awaddr => s_awaddr, m_axi_awlen => s_awlen,
            m_axi_awsize => s_awsize, m_axi_awburst => s_awburst,
            m_axi_awvalid => s_awvalid, m_axi_awready => s_awready,
            m_axi_wdata => s_wdata, m_axi_wstrb => s_wstrb, m_axi_wlast => s_wlast,
            m_axi_wvalid => s_wvalid, m_axi_wready => s_wready,
            m_axi_bid => s_bid, m_axi_bresp => s_bresp, m_axi_bvalid => s_bvalid, m_axi_bready => s_bready,
            m_axi_arid => s_arid, m_axi_araddr => s_araddr, m_axi_arlen => s_arlen,
            m_axi_arsize => s_arsize, m_axi_arburst => s_arburst,
            m_axi_arvalid => s_arvalid, m_axi_arready => s_arready,
            m_axi_rid => s_rid, m_axi_rdata => s_rdata, m_axi_rresp => s_rresp,
            m_axi_rlast => s_rlast, m_axi_rvalid => s_rvalid, m_axi_rready => s_rready,
            sb_addr => sb_addr(7 downto 0), sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
            sb_req => dma_req, sb_ack => dma_ack, sb_rdata => dma_rdata,
            irq_pb_period_o => irq_pb_period, irq_cap_period_o => irq_cap_period,
            irq_pb_underrun_o => irq_pb_underrun, irq_cap_overrun_o => irq_cap_overrun,
            sys_clk => sys_clk, sys_rst_n => rst_n,
            frame_sync_i => audioclocks.fsclk_50,
            pb_samples_o => pb_samples, cap_samples_i => cap_samples);

    ctrl_regs_inst : entity work.pcie_ctrl_regs
        generic map (VERSION => GW_VERSION)
        port map (
            clk => axi_clk, rst_n => axi_rst_n,
            sb_addr => sb_addr(7 downto 0), sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
            sb_req => ctl_req, sb_ack => ctl_ack, sb_rdata => ctl_rdata,
            eth_buf_irq_i => eth_buf_irq,
            pb_period_i => irq_pb_period, cap_period_i => irq_cap_period,
            pb_underrun_i => irq_pb_underrun, cap_overrun_i => irq_cap_overrun,
            usr_irq_req_o => usr_irq_req(0), usr_irq_ack_i => usr_irq_ack(0),
            leds_o => ctrl_leds,
            sfp_mod_abs_i => sfp_mod_abs, sfp_tx_fault_i => sfp_tx_fault, sfp_los_i => sfp_los,
            sfp_tx_disable_o => sfp_tx_disable,
            pcs_status_vector_i => pcs_status,
            pcs_configuration_vector_o => pcs_cfg_vector,
            pcs_an_restart_o => pcs_an_restart,
            pcs_reset_o => pcs_reset_req,
            pcs_resetdone_i => pcs_resetdone,
            pcs_mmcm_locked_i => pcs_mmcm_locked,
            pcs_an_interrupt_i => pcs_an_interrupt,
            user_lnk_up_i => user_lnk_up,
            sys_pll_locked_i => '1',
            mac_link_up_i => pcs_status(0));

    ------------------------------------------------------------------
    -- LEDs: 0 PCIe link, 1 Ethernet link, 2/3 host controlled,
    -- R/G host controlled, heart = 1 Hz blink from the 125 MHz data plane
    ------------------------------------------------------------------
    p_heart : process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            heartbeat_cnt <= heartbeat_cnt + 1;
        end if;
    end process;

    leds_raw(0) <= user_lnk_up;
    leds_raw(1) <= pcs_status(0);
    leds_raw(2) <= ctrl_leds(2);
    leds_raw(3) <= ctrl_leds(3);
    leds_raw(4) <= ctrl_leds(4);
    leds_raw(5) <= ctrl_leds(5);
    leds_raw(6) <= heartbeat_cnt(26);
    sfp_led_raw <= pcs_status(0);

    led_pol_n : if LED_ACTIVE_LOW generate
        led       <= not leds_raw(3 downto 0);
        led_r     <= not leds_raw(4);
        led_g     <= not leds_raw(5);
        led_heart <= not leds_raw(6);
        sfp_led   <= not sfp_led_raw;
    end generate;
    led_pol_p : if not LED_ACTIVE_LOW generate
        led       <= leds_raw(3 downto 0);
        led_r     <= leds_raw(4);
        led_g     <= leds_raw(5);
        led_heart <= leds_raw(6);
        sfp_led   <= sfp_led_raw;
    end generate;
end architecture;
