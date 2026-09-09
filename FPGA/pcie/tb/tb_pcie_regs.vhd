-- Testbench: host register path of the PCIe card.
--
--   AXI BFM (tb) -> pcie_axi_slave -> pcie_sb_decoder -> { simplebus_wb_master
--   -> Wishbone slave model (75 MHz), pcie_ctrl_regs, pcie_audio_dma regs }
--
-- Exercises 32-bit / 64-bit / burst accesses in every lane, the Wishbone
-- address translation and clock crossing, the unmapped-region and Wishbone
-- timeout error paths, and the usr_irq_req/ack protocol with level and W1C
-- sources.  Run: ghdl -r --std=08 tb_pcie_regs
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_pcie_regs is
end entity;

architecture sim of tb_pcie_regs is
    constant DW : natural := 128;
    constant AW : natural := 64;

    signal axi_clk : std_logic := '0';
    signal axi_rst_n : std_logic := '0';
    signal wb_clk : std_logic := '0';
    signal wb_rst_n : std_logic := '0';

    -- AXI
    signal awid, arid, bid, rid : std_logic_vector(3 downto 0) := (others => '0');
    signal awaddr, araddr : std_logic_vector(AW - 1 downto 0) := (others => '0');
    signal awlen, arlen : std_logic_vector(7 downto 0) := (others => '0');
    signal awsize, arsize : std_logic_vector(2 downto 0) := "010";
    signal awburst, arburst : std_logic_vector(1 downto 0) := "01";
    signal awvalid, awready, wlast, wvalid, wready : std_logic := '0';
    signal bresp, rresp : std_logic_vector(1 downto 0);
    signal bvalid, bready, arvalid, arready, rlast, rvalid, rready : std_logic := '0';
    signal wdata, rdata : std_logic_vector(DW - 1 downto 0) := (others => '0');
    signal wstrb : std_logic_vector(DW / 8 - 1 downto 0) := (others => '0');

    -- simple bus
    signal sb_addr : std_logic_vector(21 downto 0);
    signal sb_wdata, sb_rdata : std_logic_vector(31 downto 0);
    signal sb_wstrb : std_logic_vector(3 downto 0);
    signal sb_we, sb_req, sb_ack, sb_err : std_logic;
    signal wbm_req, wbm_ack, wbm_err, dma_req, dma_ack, ctl_req, ctl_ack : std_logic;
    signal wbm_rdata, dma_rdata, ctl_rdata : std_logic_vector(31 downto 0);

    -- wishbone
    signal wb_adr : std_logic_vector(29 downto 0);
    signal wb_dat_w, wb_dat_r : std_logic_vector(31 downto 0) := (others => '0');
    signal wb_sel : std_logic_vector(3 downto 0);
    signal wb_cyc, wb_stb, wb_we : std_logic;
    signal wb_ack, wb_err : std_logic := '0';
    signal wb_cti : std_logic_vector(2 downto 0);
    signal wb_bte : std_logic_vector(1 downto 0);
    type t_wbmem is array (0 to 32767) of std_logic_vector(31 downto 0);
    signal wbmem : t_wbmem := (others => (others => '0'));
    signal wb_cycles : natural := 0;

    -- ctrl regs
    signal eth_irq, pb_period, cap_period, pb_underrun, cap_overrun : std_logic := '0';
    signal usr_irq_req, usr_irq_ack : std_logic := '0';
    signal leds : std_logic_vector(7 downto 0);
    signal pcs_cfg : std_logic_vector(4 downto 0);
    signal an_restart, pcs_reset, sfp_txdis : std_logic;

    -- dma
    signal m_awvalid, m_arvalid, m_wvalid, m_bready, m_rready : std_logic;
    signal pb_samples : std_logic_vector(8 * 24 - 1 downto 0);
    signal sys_clk : std_logic := '0';
    signal frame_sync : std_logic := '0';

    signal errors : natural := 0;
begin
    axi_clk <= not axi_clk after 4 ns;    -- 125 MHz
    wb_clk  <= not wb_clk after 6.667 ns; -- 75 MHz
    sys_clk <= not sys_clk after 4 ns;
    axi_rst_n <= '1' after 100 ns;
    wb_rst_n  <= '1' after 100 ns;

    dut_slave : entity work.pcie_axi_slave
        generic map (AXI_ID_WIDTH => 4, AXI_ADDR_WIDTH => AW, AXI_DATA_WIDTH => DW, SB_ADDR_WIDTH => 22)
        port map (
            clk => axi_clk, rst_n => axi_rst_n,
            s_axi_awid => awid, s_axi_awaddr => awaddr, s_axi_awlen => awlen, s_axi_awsize => awsize,
            s_axi_awburst => awburst, s_axi_awvalid => awvalid, s_axi_awready => awready,
            s_axi_wdata => wdata, s_axi_wstrb => wstrb, s_axi_wlast => wlast, s_axi_wvalid => wvalid, s_axi_wready => wready,
            s_axi_bid => bid, s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
            s_axi_arid => arid, s_axi_araddr => araddr, s_axi_arlen => arlen, s_axi_arsize => arsize,
            s_axi_arburst => arburst, s_axi_arvalid => arvalid, s_axi_arready => arready,
            s_axi_rid => rid, s_axi_rdata => rdata, s_axi_rresp => rresp, s_axi_rlast => rlast, s_axi_rvalid => rvalid, s_axi_rready => rready,
            sb_addr => sb_addr, sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
            sb_req => sb_req, sb_ack => sb_ack, sb_rdata => sb_rdata, sb_err => sb_err);

    dut_dec : entity work.pcie_sb_decoder
        port map (sb_addr => sb_addr, sb_req => sb_req, sb_ack => sb_ack, sb_rdata => sb_rdata, sb_err => sb_err,
                  wb_req => wbm_req, wb_ack => wbm_ack, wb_rdata => wbm_rdata, wb_err => wbm_err,
                  dma_req => dma_req, dma_ack => dma_ack, dma_rdata => dma_rdata,
                  ctl_req => ctl_req, ctl_ack => ctl_ack, ctl_rdata => ctl_rdata);

    dut_wbm : entity work.simplebus_wb_master
        generic map (WB_BASE => x"90000000", SB_ADDR_WIDTH => 22, TIMEOUT_BITS => 10)
        port map (sb_clk => axi_clk, sb_rst_n => axi_rst_n,
                  sb_addr => sb_addr, sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
                  sb_req => wbm_req, sb_ack => wbm_ack, sb_rdata => wbm_rdata, sb_err => wbm_err,
                  wb_clk => wb_clk, wb_rst_n => wb_rst_n,
                  wb_adr => wb_adr, wb_dat_w => wb_dat_w, wb_dat_r => wb_dat_r, wb_sel => wb_sel,
                  wb_cyc => wb_cyc, wb_stb => wb_stb, wb_we => wb_we, wb_ack => wb_ack, wb_err => wb_err,
                  wb_cti => wb_cti, wb_bte => wb_bte);

    dut_ctl : entity work.pcie_ctrl_regs
        generic map (VERSION => x"00010002")
        port map (clk => axi_clk, rst_n => axi_rst_n,
                  sb_addr => sb_addr(7 downto 0), sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
                  sb_req => ctl_req, sb_ack => ctl_ack, sb_rdata => ctl_rdata,
                  eth_buf_irq_i => eth_irq, pb_period_i => pb_period, cap_period_i => cap_period,
                  pb_underrun_i => pb_underrun, cap_overrun_i => cap_overrun,
                  usr_irq_req_o => usr_irq_req, usr_irq_ack_i => usr_irq_ack,
                  leds_o => leds, sfp_mod_abs_i => '0', sfp_tx_fault_i => '0', sfp_los_i => '1',
                  sfp_tx_disable_o => sfp_txdis, pcs_status_vector_i => x"1234",
                  pcs_configuration_vector_o => pcs_cfg, pcs_an_restart_o => an_restart, pcs_reset_o => pcs_reset,
                  pcs_resetdone_i => '1', pcs_mmcm_locked_i => '1', pcs_an_interrupt_i => '0',
                  user_lnk_up_i => '1', sys_pll_locked_i => '1', mac_link_up_i => '0');

    dut_dma : entity work.pcie_audio_dma
        generic map (AXI_ID_WIDTH => 4, AXI_ADDR_WIDTH => AW, AXI_DATA_WIDTH => DW,
                     PB_CHANNELS => 8, CAP_CHANNELS => 8, SAMPLE_BITS => 24, FIFO_DEPTH_BITS => 6)
        port map (axi_clk => axi_clk, axi_rst_n => axi_rst_n,
                  m_axi_awid => open, m_axi_awaddr => open, m_axi_awlen => open, m_axi_awsize => open, m_axi_awburst => open,
                  m_axi_awvalid => m_awvalid, m_axi_awready => '0',
                  m_axi_wdata => open, m_axi_wstrb => open, m_axi_wlast => open, m_axi_wvalid => m_wvalid, m_axi_wready => '0',
                  m_axi_bid => "0000", m_axi_bresp => "00", m_axi_bvalid => '0', m_axi_bready => m_bready,
                  m_axi_arid => open, m_axi_araddr => open, m_axi_arlen => open, m_axi_arsize => open, m_axi_arburst => open,
                  m_axi_arvalid => m_arvalid, m_axi_arready => '0',
                  m_axi_rid => "0000", m_axi_rdata => (others => '0'), m_axi_rresp => "00", m_axi_rlast => '0',
                  m_axi_rvalid => '0', m_axi_rready => m_rready,
                  sb_addr => sb_addr(7 downto 0), sb_wdata => sb_wdata, sb_wstrb => sb_wstrb, sb_we => sb_we,
                  sb_req => dma_req, sb_ack => dma_ack, sb_rdata => dma_rdata,
                  irq_pb_period_o => open, irq_cap_period_o => open, irq_pb_underrun_o => open, irq_cap_overrun_o => open,
                  sys_clk => sys_clk, sys_rst_n => axi_rst_n, frame_sync_i => frame_sync,
                  pb_samples_o => pb_samples, cap_samples_i => (others => '0'));

    ------------------------------------------------------------------
    -- Wishbone slave model: 128 KiB window at 0x90000000; 2 wait states;
    -- offsets >= 0x20000 never answer (exercise the watchdog).
    ------------------------------------------------------------------
    p_wb : process(wb_clk)
        variable idx : integer;
        variable cnt : natural := 0;
    begin
        if rising_edge(wb_clk) then
            wb_ack <= '0';
            wb_err <= '0';
            if wb_cyc = '1' and wb_stb = '1' and wb_ack = '0' then
                idx := to_integer(unsigned(wb_adr)) - 16#24000000#;
                if idx >= 0 and idx < 32768 then
                    if cnt = 2 then
                        cnt := 0;
                        wb_ack <= '1';
                        wb_cycles <= wb_cycles + 1;
                        if wb_we = '1' then
                            for b in 0 to 3 loop
                                if wb_sel(b) = '1' then
                                    wbmem(idx)(b * 8 + 7 downto b * 8) <= wb_dat_w(b * 8 + 7 downto b * 8);
                                end if;
                            end loop;
                        else
                            wb_dat_r <= wbmem(idx);
                        end if;
                    else
                        cnt := cnt + 1;
                    end if;
                end if;
            else
                cnt := 0;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- stimulus / checks
    ------------------------------------------------------------------
    p_stim : process
        variable rd : std_logic_vector(DW - 1 downto 0);
        variable resp : std_logic_vector(1 downto 0);
        variable v32 : std_logic_vector(31 downto 0);
        variable lane : natural;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors <= errors + 1;
                report "FAIL: " & msg severity error;
            else
                report "ok: " & msg;
            end if;
        end procedure;

        procedure axi_write(addr : in unsigned(31 downto 0); size : in natural;
                            nbeats : in natural; data : in std_logic_vector(DW - 1 downto 0);
                            strb : in std_logic_vector(DW / 8 - 1 downto 0);
                            resp_o : out std_logic_vector(1 downto 0)) is
            variable a : unsigned(31 downto 0) := addr;
        begin
            awid <= x"5"; awaddr <= std_logic_vector(resize(addr, AW));
            awlen <= std_logic_vector(to_unsigned(nbeats - 1, 8));
            awsize <= std_logic_vector(to_unsigned(size, 3)); awvalid <= '1';
            loop
                wait until rising_edge(axi_clk);
                exit when awready = '1';
            end loop;
            awvalid <= '0';
            for b in 1 to nbeats loop
                wdata <= data; wstrb <= strb; wvalid <= '1';
                if b = nbeats then wlast <= '1'; else wlast <= '0'; end if;
                loop
                    wait until rising_edge(axi_clk);
                    exit when wready = '1';
                end loop;
                wvalid <= '0'; wlast <= '0';
                -- shift strobe/data to the next lane pair for burst tests
                a := a + 2 ** size;
            end loop;
            bready <= '1';
            loop
                wait until rising_edge(axi_clk);
                exit when bvalid = '1';
            end loop;
            resp_o := bresp;
            check(bid = x"5", "write ID echoed");
            bready <= '0';
        end procedure;

        procedure axi_read(addr : in unsigned(31 downto 0); size : in natural; nbeats : in natural;
                           data_o : out std_logic_vector(DW - 1 downto 0);
                           resp_o : out std_logic_vector(1 downto 0)) is
        begin
            arid <= x"9"; araddr <= std_logic_vector(resize(addr, AW));
            arlen <= std_logic_vector(to_unsigned(nbeats - 1, 8));
            arsize <= std_logic_vector(to_unsigned(size, 3)); arvalid <= '1';
            loop
                wait until rising_edge(axi_clk);
                exit when arready = '1';
            end loop;
            arvalid <= '0';
            rready <= '1';
            for b in 1 to nbeats loop
                loop
                    wait until rising_edge(axi_clk);
                    exit when rvalid = '1';
                end loop;
                data_o := rdata;      -- last beat wins; burst test reads lanes
                resp_o := rresp;
                check(rid = x"9", "read ID echoed");
                if b = nbeats then check(rlast = '1', "rlast on last beat");
                else check(rlast = '0', "no rlast mid burst"); end if;
            end loop;
            rready <= '0';
        end procedure;

        procedure write32(addr : in unsigned(31 downto 0); val : in std_logic_vector(31 downto 0)) is
            variable d : std_logic_vector(DW - 1 downto 0) := (others => '0');
            variable s : std_logic_vector(DW / 8 - 1 downto 0) := (others => '0');
            variable l : natural;
            variable r : std_logic_vector(1 downto 0);
        begin
            l := to_integer(addr(3 downto 2));
            d(l * 32 + 31 downto l * 32) := val;
            s(l * 4 + 3 downto l * 4) := "1111";
            axi_write(addr, 2, 1, d, s, r);
            check(r = "00", "write32 OKAY @" & integer'image(to_integer(addr)));
        end procedure;

        procedure read32(addr : in unsigned(31 downto 0); val_o : out std_logic_vector(31 downto 0);
                         resp_o : out std_logic_vector(1 downto 0)) is
            variable d : std_logic_vector(DW - 1 downto 0);
            variable l : natural;
        begin
            l := to_integer(addr(3 downto 2));
            axi_read(addr, 2, 1, d, resp_o);
            val_o := d(l * 32 + 31 downto l * 32);
        end procedure;

        procedure expect32(addr : in unsigned(31 downto 0); exp : in std_logic_vector(31 downto 0); msg : string) is
            variable v : std_logic_vector(31 downto 0);
            variable r : std_logic_vector(1 downto 0);
        begin
            read32(addr, v, r);
            check(r = "00" and v = exp, msg & " (got " & to_hstring(v) & ")");
        end procedure;

        variable d128 : std_logic_vector(DW - 1 downto 0);
        variable s16 : std_logic_vector(DW / 8 - 1 downto 0);
        variable n_before : natural;
    begin
        wait until axi_rst_n = '1';
        wait for 200 ns;
        wait until rising_edge(axi_clk);

        -- control block
        expect32(x"00200000", x"AE670001", "ID register");
        expect32(x"00200004", x"00010002", "VERSION register");
        write32(x"00200020", x"CAFEBABE");
        expect32(x"00200020", x"CAFEBABE", "scratch readback");
        write32(x"00200010", x"000000A5");
        wait for 50 ns;
        check(leds = x"A5", "LED register drives leds_o");
        expect32(x"00200014", x"12340004", "SFP status: LOS + pcs status vector");
        expect32(x"0020001C", x"0000000F", "link status bits");
        expect32(x"00200018", x"00000010", "PCS ctrl reset value (AN enabled)");

        -- Wishbone window: all four lanes, address translation, byte enables
        write32(x"00000000", x"DEADBEEF");
        write32(x"00000004", x"11111111");
        write32(x"00000008", x"22222222");
        write32(x"0000000C", x"33333333");
        write32(x"00010018", x"0BADF00D");   -- CSR region offset
        wait for 100 ns;
        check(wbmem(0) = x"DEADBEEF" and wbmem(1) = x"11111111" and wbmem(2) = x"22222222" and wbmem(3) = x"33333333",
              "wishbone words landed at the translated word addresses");
        check(wbmem(16#10018# / 4) = x"0BADF00D", "CSR-region write translated (0x90010018)");
        expect32(x"00000000", x"DEADBEEF", "wishbone readback lane 0");
        expect32(x"0000000C", x"33333333", "wishbone readback lane 3");
        expect32(x"00010018", x"0BADF00D", "wishbone readback CSR region");
        -- byte-enable: 16-bit write (size 1) into lane 1 high half
        d128 := (others => '0'); s16 := (others => '0');
        d128(63 downto 48) := x"5A5A"; s16(7 downto 6) := "11";
        axi_write(x"00000006", 1, 1, d128, s16, resp);
        wait for 100 ns;
        check(wbmem(1) = x"5A5A1111", "16-bit write forwarded wb_sel (got " & to_hstring(wbmem(1)) & ")");

        -- 64-bit access spanning two lanes (DMA PB_ADDR_LO/HI)
        d128 := (others => '0'); s16 := (others => '0');
        d128(63 downto 0) := x"0000000100002000"; s16(7 downto 0) := x"FF";
        axi_write(x"00100010", 3, 1, d128, s16, resp);
        check(resp = "00", "64-bit write OKAY");
        expect32(x"00100010", x"00002000", "PB_ADDR_LO from 64-bit write");
        expect32(x"00100014", x"00000001", "PB_ADDR_HI from 64-bit write");
        axi_read(x"00100010", 3, 1, d128, resp);
        check(resp = "00" and d128(63 downto 0) = x"0000000100002000", "64-bit read returns both lanes");
        check(d128(127 downto 64) = x"0000000000000000", "64-bit read leaves other lanes zero");

        -- 2-beat INCR burst of 32-bit transfers: PB_RING (0x18, lane 2) + PB_PERIOD (0x1C, lane 3)
        d128 := (others => '0'); s16 := (others => '0');
        d128(95 downto 64) := x"00003000"; d128(127 downto 96) := x"00000400";
        s16(11 downto 8) := "1111"; s16(15 downto 12) := "1111";
        -- one wdata word is reused for both beats; the slave must only take
        -- the lane addressed by each beat (beat1 -> lane 2, beat2 -> lane 3)
        awid <= x"5"; awaddr <= std_logic_vector(to_unsigned(16#00100018#, AW));
        awlen <= x"01"; awsize <= "010"; awvalid <= '1';
        loop wait until rising_edge(axi_clk); exit when awready = '1'; end loop;
        awvalid <= '0';
        wdata <= d128; wstrb <= s16 and x"0F00"; wvalid <= '1'; wlast <= '0';
        loop wait until rising_edge(axi_clk); exit when wready = '1'; end loop;
        wstrb <= s16 and x"F000"; wlast <= '1';
        loop wait until rising_edge(axi_clk); exit when wready = '1'; end loop;
        wvalid <= '0'; wlast <= '0'; bready <= '1';
        loop wait until rising_edge(axi_clk); exit when bvalid = '1'; end loop;
        check(bresp = "00", "burst write OKAY");
        bready <= '0';
        expect32(x"00100018", x"00003000", "PB_RING from burst beat 1");
        expect32(x"0010001C", x"00000400", "PB_PERIOD from burst beat 2");
        -- 2-beat burst read of the same two registers
        arid <= x"9"; araddr <= std_logic_vector(to_unsigned(16#00100018#, AW));
        arlen <= x"01"; arsize <= "010"; arvalid <= '1';
        loop wait until rising_edge(axi_clk); exit when arready = '1'; end loop;
        arvalid <= '0'; rready <= '1';
        loop wait until rising_edge(axi_clk); exit when rvalid = '1'; end loop;
        check(rdata(95 downto 64) = x"00003000" and rlast = '0', "burst read beat 1 lane 2");
        loop wait until rising_edge(axi_clk); exit when rvalid = '1'; end loop;
        check(rdata(127 downto 96) = x"00000400" and rlast = '1', "burst read beat 2 lane 3");
        rready <= '0';
        expect32(x"00100008", x"06100808", "DMA CAPS: fifo bits 6, 16 B beats, 8+8 channels");

        -- error paths
        read32(x"00300000", v32, resp);
        check(resp = "10" and v32 = x"BADADD00", "unmapped region -> SLVERR");
        n_before := wb_cycles;
        read32(x"00020000", v32, resp);
        check(resp = "10" and v32 = x"DEADBEEF", "wishbone watchdog -> SLVERR after timeout");
        check(wb_cycles = n_before, "no wishbone ack for the timed-out access");
        -- bus still alive afterwards
        expect32(x"00000008", x"22222222", "wishbone path recovers after timeout");

        -- interrupts: W1C source
        write32(x"0020000C", x"0000001F");
        check(usr_irq_req = '0', "no IRQ while nothing pending");
        pb_period <= '1'; wait until rising_edge(axi_clk); pb_period <= '0';
        wait for 100 ns;
        check(usr_irq_req = '1', "period event raises usr_irq_req");
        usr_irq_ack <= '1'; wait until rising_edge(axi_clk); usr_irq_ack <= '0';
        wait for 40 ns;
        check(usr_irq_req = '0', "usr_irq_req released after ack");
        expect32(x"00200008", x"00000002", "IRQ status shows pending bit1");
        wait for 400 ns;
        check(usr_irq_req = '1', "still pending after cooldown -> re-asserted");
        usr_irq_ack <= '1'; wait until rising_edge(axi_clk); usr_irq_ack <= '0';
        write32(x"00200008", x"00000002");   -- W1C
        wait for 600 ns;
        check(usr_irq_req = '0', "cleared source stays quiet");
        expect32(x"00200008", x"00000000", "IRQ status clear after W1C");

        -- interrupts: level source (eth_buf)
        eth_irq <= '1';
        wait for 100 ns;
        check(usr_irq_req = '1', "eth_buf level raises usr_irq_req");
        expect32(x"00200008", x"00000001", "IRQ status bit0 follows eth_buf level");
        write32(x"0020000C", x"0000001E");   -- mask it like the driver does
        usr_irq_ack <= '1'; wait until rising_edge(axi_clk); usr_irq_ack <= '0';
        wait for 600 ns;
        check(usr_irq_req = '0', "masked level source does not re-assert");
        eth_irq <= '0';
        write32(x"0020000C", x"0000001F");
        wait for 600 ns;
        check(usr_irq_req = '0', "dropped level stays quiet when re-enabled");

        wait for 100 ns;
        if errors = 0 then
            report "tb_pcie_regs PASSED" severity note;
        else
            report "tb_pcie_regs FAILED with " & integer'image(errors) & " errors" severity error;
        end if;
        finish;
    end process;
end architecture;
