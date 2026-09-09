-- Testbench: bus-mastering audio DMA engine against a host-memory model.
--
-- The AXI slave model is a 64 KiB "host RAM" with random-ish handshake
-- delays that also checks that no burst crosses a 4 KiB boundary. Playback
-- ring holds a known pattern; every frame handed to pb_samples_o is compared
-- against it (across ring wrap, burst splits at 4 KiB / ring end, and an
-- injected host stall that must produce counted underruns, silence and a
-- clean resume). Capture drives a pattern into cap_samples_i and checks what
-- landed in host memory, plus period interrupt counts and pointer lag.
-- Run: ghdl -r --std=08 tb_pcie_audio_dma
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_pcie_audio_dma is
    generic (
        CH : natural := 8      -- channels per direction (frame = CH*4 bytes)
    );
end entity;

architecture sim of tb_pcie_audio_dma is
    constant DW : natural := 128;
    constant AW : natural := 64;
    constant FRAME_BYTES : natural := CH * 4;
    constant PB_BASE  : natural := 16#1080#;
    constant CAP_BASE : natural := 16#5080#;
    constant RING_FRAMES : natural := (3 * 4096 + 256) / FRAME_BYTES;   -- 392 for CH=8
    constant RING_BYTES  : natural := RING_FRAMES * FRAME_BYTES;
    constant PERIOD_BYTES : natural := 1024;
    constant FS_HALF : natural := 200;      -- sys clocks per half frame

    signal axi_clk, sys_clk : std_logic := '0';
    signal rst_n : std_logic := '0';

    -- AXI master from DUT
    signal awid, arid : std_logic_vector(3 downto 0);
    signal awaddr, araddr : std_logic_vector(AW - 1 downto 0);
    signal awlen, arlen : std_logic_vector(7 downto 0);
    signal awsize, arsize : std_logic_vector(2 downto 0);
    signal awburst, arburst : std_logic_vector(1 downto 0);
    signal awvalid, awready, wlast, wvalid, wready : std_logic := '0';
    signal bvalid, bready, arvalid, arready, rlast, rvalid, rready : std_logic := '0';
    signal wdata, rdata : std_logic_vector(DW - 1 downto 0) := (others => '0');
    signal wstrb : std_logic_vector(DW / 8 - 1 downto 0);

    -- regs
    signal sb_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal sb_wdata, sb_rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal sb_we, sb_req, sb_ack : std_logic := '0';

    signal irq_pb, irq_cap, irq_pbu, irq_capo : std_logic;
    signal frame_sync : std_logic := '0';
    signal pb_samples : std_logic_vector(CH * 24 - 1 downto 0);
    signal cap_samples : std_logic_vector(CH * 24 - 1 downto 0) := (others => '0');

    type t_mem is array (0 to 4095) of std_logic_vector(DW - 1 downto 0);
    signal mem : t_mem := (others => (others => '0'));
    signal host_stall, host_stall_wr : std_logic := '0';   -- block host reads / writes
    signal errors, err_rd, err_wr, err_pb : natural := 0;   -- one driver per process
    signal n_pb_irq, n_cap_irq : natural := 0;
    signal pb_running, cap_running : boolean := false;
    signal pb_frames_ok, pb_underruns_seen : natural := 0;
    signal cap_frame_idx : natural := 0;

    function pb_sample(f, c : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((f * 256 + c) mod 2 ** 24, 24));
    end function;
    function cap_sample(f, c : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((16#800000# + f * 256 + c) mod 2 ** 24, 24));
    end function;
begin
    axi_clk <= not axi_clk after 4 ns;
    sys_clk <= not sys_clk after 4 ns;
    rst_n <= '1' after 100 ns;

    dut : entity work.pcie_audio_dma
        generic map (AXI_ID_WIDTH => 4, AXI_ADDR_WIDTH => AW, AXI_DATA_WIDTH => DW,
                     PB_CHANNELS => CH, CAP_CHANNELS => CH, SAMPLE_BITS => 24, FIFO_DEPTH_BITS => 6)
        port map (axi_clk => axi_clk, axi_rst_n => rst_n,
                  m_axi_awid => awid, m_axi_awaddr => awaddr, m_axi_awlen => awlen, m_axi_awsize => awsize,
                  m_axi_awburst => awburst, m_axi_awvalid => awvalid, m_axi_awready => awready,
                  m_axi_wdata => wdata, m_axi_wstrb => wstrb, m_axi_wlast => wlast, m_axi_wvalid => wvalid, m_axi_wready => wready,
                  m_axi_bid => "0000", m_axi_bresp => "00", m_axi_bvalid => bvalid, m_axi_bready => bready,
                  m_axi_arid => arid, m_axi_araddr => araddr, m_axi_arlen => arlen, m_axi_arsize => arsize,
                  m_axi_arburst => arburst, m_axi_arvalid => arvalid, m_axi_arready => arready,
                  m_axi_rid => "0000", m_axi_rdata => rdata, m_axi_rresp => "00", m_axi_rlast => rlast,
                  m_axi_rvalid => rvalid, m_axi_rready => rready,
                  sb_addr => sb_addr, sb_wdata => sb_wdata, sb_wstrb => "1111", sb_we => sb_we,
                  sb_req => sb_req, sb_ack => sb_ack, sb_rdata => sb_rdata,
                  irq_pb_period_o => irq_pb, irq_cap_period_o => irq_cap,
                  irq_pb_underrun_o => irq_pbu, irq_cap_overrun_o => irq_capo,
                  sys_clk => sys_clk, sys_rst_n => rst_n, frame_sync_i => frame_sync,
                  pb_samples_o => pb_samples, cap_samples_i => cap_samples);

    ------------------------------------------------------------------
    -- host memory model: AXI read channel
    ------------------------------------------------------------------
    p_host_rd : process
        variable addr : natural;
        variable beats : natural;
        variable lfsr : unsigned(7 downto 0) := x"5A";
    begin
        arready <= '0'; rvalid <= '0';
        wait until rising_edge(axi_clk) and arvalid = '1' and host_stall = '0';
        assert unsigned(arsize) = 4 and arburst = "01" report "read: bad size/burst" severity error;
        addr := to_integer(unsigned(araddr(15 downto 0)));
        beats := to_integer(unsigned(arlen)) + 1;
        if (addr mod 4096) + beats * 16 > 4096 then
            err_rd <= err_rd + 1;
            report "FAIL: read burst crosses 4 KiB at " & integer'image(addr) severity error;
        end if;
        arready <= '1';
        wait until rising_edge(axi_clk);
        arready <= '0';
        for b in 0 to beats - 1 loop
            lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
            for w in 1 to to_integer(lfsr(1 downto 0)) loop
                wait until rising_edge(axi_clk);
            end loop;
            rdata <= mem(addr / 16 + b);
            rvalid <= '1';
            if b = beats - 1 then rlast <= '1'; else rlast <= '0'; end if;
            wait until rising_edge(axi_clk) and rready = '1';
            rvalid <= '0'; rlast <= '0';
        end loop;
    end process;

    ------------------------------------------------------------------
    -- host memory model: AXI write channel
    ------------------------------------------------------------------
    p_host_wr : process
        variable addr : natural;
        variable beats : natural;
        variable lfsr : unsigned(7 downto 0) := x"C3";
        variable init_done : boolean := false;
    begin
        if not init_done then
            -- fill the playback ring: frame f, channel c -> (f*256+c) << 8
            -- (this process is the only driver of mem)
            for f in 0 to RING_FRAMES - 1 loop
                for c in 0 to CH - 1 loop
                    mem((PB_BASE + f * FRAME_BYTES + c * 4) / 16)(((c * 4) mod 16) * 8 + 31 downto ((c * 4) mod 16) * 8)
                        <= pb_sample(f, c) & x"00";
                end loop;
            end loop;
            init_done := true;
        end if;
        awready <= '0'; wready <= '0'; bvalid <= '0';
        wait until rising_edge(axi_clk) and awvalid = '1' and host_stall_wr = '0';
        assert unsigned(awsize) = 4 and awburst = "01" report "write: bad size/burst" severity error;
        addr := to_integer(unsigned(awaddr(15 downto 0)));
        beats := to_integer(unsigned(awlen)) + 1;
        if (addr mod 4096) + beats * 16 > 4096 then
            err_wr <= err_wr + 1;
            report "FAIL: write burst crosses 4 KiB at " & integer'image(addr) severity error;
        end if;
        awready <= '1';
        wait until rising_edge(axi_clk);
        awready <= '0';
        for b in 0 to beats - 1 loop
            lfsr := lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
            for w in 1 to to_integer(lfsr(1 downto 0)) loop
                wait until rising_edge(axi_clk);
            end loop;
            wready <= '1';
            wait until rising_edge(axi_clk) and wvalid = '1';
            assert wstrb = (wstrb'range => '1') report "write: partial strobe" severity error;
            if (b = beats - 1) /= (wlast = '1') then
                err_wr <= err_wr + 1;
                report "FAIL: wlast misplaced" severity error;
            end if;
            mem(addr / 16 + b) <= wdata;
            wready <= '0';
        end loop;
        wait until rising_edge(axi_clk);
        bvalid <= '1';
        wait until rising_edge(axi_clk) and bready = '1';
        bvalid <= '0';
    end process;

    ------------------------------------------------------------------
    -- frame clock, IRQ counters
    ------------------------------------------------------------------
    p_fs : process
    begin
        for i in 1 to FS_HALF loop wait until rising_edge(sys_clk); end loop;
        frame_sync <= not frame_sync;
    end process;

    p_irq : process(axi_clk)
    begin
        if rising_edge(axi_clk) then
            if irq_pb = '1' then n_pb_irq <= n_pb_irq + 1; end if;
            if irq_cap = '1' then n_cap_irq <= n_cap_irq + 1; end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- playback checker: sample pb_samples_o shortly after each falling
    -- frame_sync edge and compare with the expected frame
    ------------------------------------------------------------------
    p_pb_check : process
        variable f : natural := 0;
        variable exp : std_logic_vector(CH * 24 - 1 downto 0);
        variable zero : std_logic_vector(CH * 24 - 1 downto 0) := (others => '0');
    begin
        wait until falling_edge(frame_sync);
        for i in 1 to 4 loop wait until rising_edge(sys_clk); end loop;
        if pb_running then
            for c in 0 to CH - 1 loop
                exp((c + 1) * 24 - 1 downto c * 24) := pb_sample(f mod RING_FRAMES, c);
            end loop;
            if pb_samples = exp then
                f := f + 1;
                pb_frames_ok <= pb_frames_ok + 1;
            elsif pb_samples = zero then
                pb_underruns_seen <= pb_underruns_seen + 1;   -- silence, frame not consumed
            else
                err_pb <= err_pb + 1;
                report "FAIL: playback frame " & integer'image(f) & " mismatch: got " &
                       to_hstring(pb_samples(47 downto 0)) & " exp " & to_hstring(exp(47 downto 0)) severity error;
                f := f + 1;
            end if;
        end if;
    end process;

    -- capture stimulus: present frame k's pattern before falling edge k
    p_cap_drive : process
        variable f : natural := 0;
    begin
        wait until rising_edge(frame_sync);
        if cap_running then
            for c in 0 to CH - 1 loop
                cap_samples((c + 1) * 24 - 1 downto c * 24) <= cap_sample(f, c);
            end loop;
            f := f + 1;
            cap_frame_idx <= f;
        end if;
    end process;

    ------------------------------------------------------------------
    -- main stimulus
    ------------------------------------------------------------------
    p_main : process
        procedure reg_write(off : natural; val : std_logic_vector(31 downto 0)) is
        begin
            sb_addr <= std_logic_vector(to_unsigned(off, 8)); sb_wdata <= val; sb_we <= '1'; sb_req <= '1';
            wait until rising_edge(axi_clk) and sb_ack = '1';
            sb_req <= '0'; sb_we <= '0';
            wait until rising_edge(axi_clk);
        end procedure;
        procedure reg_read(off : natural; val : out std_logic_vector(31 downto 0)) is
        begin
            sb_addr <= std_logic_vector(to_unsigned(off, 8)); sb_we <= '0'; sb_req <= '1';
            wait until rising_edge(axi_clk) and sb_ack = '1';
            val := sb_rdata;
            sb_req <= '0';
            wait until rising_edge(axi_clk);
        end procedure;
        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors <= errors + 1;
                report "FAIL: " & msg severity error;
            else
                report "ok: " & msg;
            end if;
        end procedure;
        procedure wait_frames(n : natural) is
        begin
            for i in 1 to n loop wait until falling_edge(frame_sync); end loop;
        end procedure;

        variable v : std_logic_vector(31 downto 0);
        variable w : std_logic_vector(DW - 1 downto 0);
        variable lag, consumed, hw : natural;
        variable slot, fexp, fmax : natural;
        variable exp_word : std_logic_vector(DW - 1 downto 0);
        variable ok : boolean;
        variable underruns_hw, overruns_hw : natural;
    begin
        wait until rst_n = '1';
        wait for 100 ns;
        wait until rising_edge(axi_clk);

        reg_read(16#08#, v);
        check(unsigned(v) = to_unsigned(16#06100000# + CH * 256 + CH, 32), "CAPS register");
        reg_write(16#0C#, x"00001010");                     -- 16-beat bursts both ways
        reg_write(16#10#, std_logic_vector(to_unsigned(PB_BASE, 32)));
        reg_write(16#14#, x"00000000");
        reg_write(16#18#, std_logic_vector(to_unsigned(RING_BYTES, 32)));
        reg_write(16#1C#, std_logic_vector(to_unsigned(PERIOD_BYTES, 32)));
        reg_write(16#30#, std_logic_vector(to_unsigned(CAP_BASE, 32)));
        reg_write(16#34#, x"00000000");
        reg_write(16#38#, std_logic_vector(to_unsigned(RING_BYTES, 32)));
        reg_write(16#3C#, std_logic_vector(to_unsigned(PERIOD_BYTES, 32)));
        reg_read(16#18#, v);
        check(v = std_logic_vector(to_unsigned(RING_BYTES, 32)), "PB_RING readback");

        -- start both directions right after a falling edge
        wait until falling_edge(frame_sync);
        wait until rising_edge(axi_clk);
        reg_write(16#00#, x"00000003");
        pb_running <= true; cap_running <= true;

        wait_frames(100);
        check(pb_frames_ok >= 99 and pb_underruns_seen = 0, "100 playback frames delivered without underrun (ok="
              & integer'image(pb_frames_ok) & ")");

        -- host stall: longer than the 32-frame prefetch FIFO -> underruns
        host_stall <= '1';
        wait_frames(50);
        host_stall <= '0';
        check(pb_underruns_seen > 5, "host stall produced silent frames (" & integer'image(pb_underruns_seen) & ")");
        -- short write stall: fits into the capture FIFO, must not lose frames
        wait_frames(20);
        host_stall_wr <= '1';
        wait_frames((64 / (FRAME_BYTES / 16)) / 2);
        host_stall_wr <= '0';
        wait_frames(350);                                   -- past the ring wrap
        reg_read(16#24#, v); underruns_hw := to_integer(unsigned(v));
        check(underruns_hw = pb_underruns_seen, "PB_UNDERRUNS counter = silent frames seen (hw " &
              integer'image(underruns_hw) & ", tb " & integer'image(pb_underruns_seen) & ")");
        check(pb_frames_ok > RING_FRAMES + 50, "playback continued correctly across the ring wrap (frames ok="
              & integer'image(pb_frames_ok) & ")");
        reg_read(16#04#, v);
        check(v(4) = '1' and v(6) = '0', "STATUS: sticky underrun set, no AXI error");
        reg_write(16#04#, x"00000010");
        reg_read(16#04#, v);
        check(v(4) = '0', "STATUS underrun W1C");

        -- hw pointer: may lead the frames seen on pb_samples_o by the one
        -- frame being assembled, may lag by the FIFO contents
        reg_read(16#20#, v); hw := to_integer(unsigned(v));
        consumed := ((pb_frames_ok + 1) * FRAME_BYTES) mod RING_BYTES;
        lag := (consumed + RING_BYTES - hw) mod RING_BYTES;
        check(lag <= 64 * 16 + 2 * FRAME_BYTES, "PB_HW_PTR within [-1 frame, +FIFO] of the audible position (" &
              integer'image(lag) & " bytes behind consumed+1)");
        check(hw mod 16 = 0 and hw < RING_BYTES, "PB_HW_PTR inside ring and beat aligned");
        check(n_pb_irq >= (pb_frames_ok * FRAME_BYTES) / PERIOD_BYTES - 2 and
              n_pb_irq <= (pb_frames_ok * FRAME_BYTES) / PERIOD_BYTES + 1,
              "playback period IRQ count " & integer'image(n_pb_irq) & " ~ consumed/period");

        -- capture: stop right after a frame boundary (before the engine can
        -- latch the last pattern a second time); whatever is still in the
        -- FIFO is dropped, like an ALSA stop
        wait until falling_edge(frame_sync);
        cap_running <= false;
        pb_running <= false;
        fmax := cap_frame_idx;
        wait until rising_edge(axi_clk);
        reg_write(16#00#, x"00000000");
        wait for 2 us;
        reg_read(16#44#, v); overruns_hw := to_integer(unsigned(v));
        check(overruns_hw = 0, "no capture overruns");
        -- every slot except the last (possibly unwritten) 8 frames holds its pattern
        for f in 0 to fmax - 9 loop
            slot := f mod RING_FRAMES;
            if f + RING_FRAMES <= fmax - 9 then
                next;   -- overwritten by a later, checked frame
            end if;
            ok := true;
            for c in 0 to CH - 1 loop
                w := mem((CAP_BASE + slot * FRAME_BYTES + c * 4) / 16);
                if w(((c * 4) mod 16) * 8 + 31 downto ((c * 4) mod 16) * 8) /= cap_sample(f, c) & x"00" then
                    -- tolerate the tail slots being overwritten by frames beyond fmax-9
                    if f + RING_FRAMES <= fmax and
                       w(((c * 4) mod 16) * 8 + 31 downto ((c * 4) mod 16) * 8) = cap_sample(f + RING_FRAMES, c) & x"00" then
                        null;
                    else
                        ok := false;
                    end if;
                end if;
            end loop;
            if not ok then
                errors <= errors + 1;
                report "FAIL: capture frame " & integer'image(f) & " wrong in host memory" severity error;
            end if;
        end loop;
        check(true, "capture ring content verified for " & integer'image(fmax - 8) & " frames");
        reg_read(16#40#, v); hw := to_integer(unsigned(v));
        check(hw mod FRAME_BYTES = 0 and hw < RING_BYTES, "CAP_HW_PTR frame aligned inside ring");
        check(n_cap_irq >= ((fmax - 8) * FRAME_BYTES) / PERIOD_BYTES - 1 and
              n_cap_irq <= (fmax * FRAME_BYTES) / PERIOD_BYTES + 1,
              "capture period IRQ count " & integer'image(n_cap_irq) & " ~ written/period");
        reg_read(16#50#, v);
        check(to_integer(unsigned(v)) > 400, "FS_COUNT counts frame ticks (" & integer'image(to_integer(unsigned(v))) & ")");

        if errors + err_rd + err_wr + err_pb = 0 then
            report "tb_pcie_audio_dma PASSED (CH=" & integer'image(CH) & ")" severity note;
        else
            report "tb_pcie_audio_dma FAILED with " & integer'image(errors + err_rd + err_wr + err_pb) & " errors" severity error;
        end if;
        finish;
    end process;
end architecture;
