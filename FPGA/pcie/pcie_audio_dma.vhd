-- PCIe audio DMA engine: host ring buffers <-> AES67 parallel sample registers.
--
-- Makes the FPGA a bus-mastering sound card. The Linux ALSA driver allocates
-- one ring buffer per direction in host memory and programs its bus address,
-- size and period here; the engine then streams continuously at the AES67
-- media clock rate:
--
--   playback (host -> network TX):  AXI reads  ring -> FIFO -> pb_samples_o
--   capture  (network RX -> host):  cap_samples_i -> FIFO -> AXI writes ring
--
-- Frame format in host memory: interleaved S32_LE, one 32-bit word per
-- channel, sample in the upper SAMPLE_BITS bits (ALSA S32_LE with 24 valid
-- bits). A frame is CHANNELS*4 bytes; CHANNELS*32 must be a multiple of the
-- AXI data width so a frame is a whole number of beats.
--
-- Clock domains
--   axi_clk : AXI master, registers, ring pointers, interrupts.
--   sys_clk : 125 MHz AES67 data plane. frame_sync_i is the 50 %-duty frame
--             clock generated in that domain (audioclocks.fsclk_50); the
--             sample registers are exchanged on its falling edge, half a
--             frame away from the boundary on which the AES67 TX buffer latches
--             tx_sample_register and the RX playout rewrites rx_sample_register.
--
-- Pointers reported to the host
--   PB_HW_PTR : bytes consumed = bytes fetched minus bytes still in the FIFO.
--               The frame currently being assembled from the FIFO counts as
--               consumed, so the pointer leads the audible position by at
--               most one frame (~21 us) and, because the FIFO's write-side
--               occupancy lags, never by more than what has already been
--               fetched out of the ring. Safe for ALSA: everything below the
--               pointer has left host memory.
--   CAP_HW_PTR: bytes whose AXI write has completed (BRESP received), so the
--               host never reads a frame that is not in memory yet.
-- Period interrupts pulse whenever the respective pointer crosses a multiple
-- of *_PERIOD_BYTES (modular arithmetic, so any period size that divides the
-- ring works).
--
-- Register map (byte offsets, 32-bit, BAR0 + 0x100000):
--   0x00 CTRL         RW   bit0 PB_RUN, bit1 CAP_RUN (0->1 restarts the
--                          direction from ring offset 0 with a flushed FIFO)
--   0x04 STATUS       R/W1C bit0 pb running, bit1 cap running,
--                          bit4 pb underrun (sticky), bit5 cap overrun
--                          (sticky), bit6 AXI error (sticky)
--   0x08 CAPS         RO   [7:0] playback channels, [15:8] capture channels,
--                          [23:16] bytes per AXI beat, [31:24] FIFO depth bits
--   0x0C BURST        RW   [7:0] playback burst beats, [15:8] capture burst
--                          beats (clamped to 1 .. FIFO depth / 2)
--   0x10 PB_ADDR_LO   RW   playback ring bus address, low 32 bits
--   0x14 PB_ADDR_HI   RW   high 32 bits
--   0x18 PB_RING      RW   ring size in bytes (multiple of the beat size)
--   0x1C PB_PERIOD    RW   period size in bytes
--   0x20 PB_HW_PTR    RO   byte offset into the ring (see above)
--   0x24 PB_UNDERRUNS RO   frames output as silence because the FIFO was empty
--   0x30 CAP_ADDR_LO  RW   0x34 CAP_ADDR_HI  0x38 CAP_RING  0x3C CAP_PERIOD
--   0x40 CAP_HW_PTR   RO   0x44 CAP_OVERRUNS RO (frames dropped, FIFO full)
--   0x50 FS_COUNT     RO   frame ticks seen since reset (debug)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcie_audio_dma is
    generic (
        AXI_ID_WIDTH   : positive := 4;
        AXI_ADDR_WIDTH : positive := 64;
        AXI_DATA_WIDTH : positive := 128;
        PB_CHANNELS    : positive := 32;   -- host -> AES67 TX
        CAP_CHANNELS   : positive := 32;   -- AES67 RX -> host
        SAMPLE_BITS    : positive := 24;   -- width of one parallel-register sample
        FIFO_DEPTH_BITS: positive := 6
    );
    port (
        ------------------------------------------------------------------
        -- AXI clock domain
        ------------------------------------------------------------------
        axi_clk   : in std_logic;
        axi_rst_n : in std_logic;

        -- AXI4 master
        m_axi_awid    : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        m_axi_awaddr  : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
        m_axi_awlen   : out std_logic_vector(7 downto 0);
        m_axi_awsize  : out std_logic_vector(2 downto 0);
        m_axi_awburst : out std_logic_vector(1 downto 0);
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        m_axi_wdata   : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
        m_axi_wstrb   : out std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
        m_axi_wlast   : out std_logic;
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        m_axi_bid     : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic;
        m_axi_arid    : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        m_axi_araddr  : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
        m_axi_arlen   : out std_logic_vector(7 downto 0);
        m_axi_arsize  : out std_logic_vector(2 downto 0);
        m_axi_arburst : out std_logic_vector(1 downto 0);
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        m_axi_rid     : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        m_axi_rdata   : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rlast   : in  std_logic;
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic;

        -- simple bus slave (byte offset inside the region)
        sb_addr  : in  std_logic_vector(7 downto 0);
        sb_wdata : in  std_logic_vector(31 downto 0);
        sb_wstrb : in  std_logic_vector(3 downto 0);
        sb_we    : in  std_logic;
        sb_req   : in  std_logic;
        sb_ack   : out std_logic;
        sb_rdata : out std_logic_vector(31 downto 0);

        -- interrupt pulses
        irq_pb_period_o   : out std_logic;
        irq_cap_period_o  : out std_logic;
        irq_pb_underrun_o : out std_logic;
        irq_cap_overrun_o : out std_logic;

        ------------------------------------------------------------------
        -- AES67 data-plane clock domain
        ------------------------------------------------------------------
        sys_clk       : in  std_logic;
        sys_rst_n     : in  std_logic;
        frame_sync_i  : in  std_logic;   -- audioclocks.fsclk_50 (sys_clk domain)
        pb_samples_o  : out std_logic_vector(PB_CHANNELS * SAMPLE_BITS - 1 downto 0);
        cap_samples_i : in  std_logic_vector(CAP_CHANNELS * SAMPLE_BITS - 1 downto 0)
    );
end entity;

architecture rtl of pcie_audio_dma is
    constant DW         : natural := AXI_DATA_WIDTH;
    constant BEAT_BYTES : natural := DW / 8;
    constant PB_WPF     : natural := PB_CHANNELS * 32 / DW;    -- words per frame
    constant CAP_WPF    : natural := CAP_CHANNELS * 32 / DW;
    constant FIFO_DEPTH : natural := 2 ** FIFO_DEPTH_BITS;
    constant MAX_BURST  : natural := FIFO_DEPTH / 2;

    function clog2(n : natural) return natural is
        variable r : natural := 0;
        variable v : natural := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function;
    constant BEAT_BITS  : natural := clog2(BEAT_BYTES);
    constant AXSIZE     : std_logic_vector(2 downto 0) := std_logic_vector(to_unsigned(BEAT_BITS, 3));

    ------------------------------------------------------------------
    -- registers (axi domain)
    ------------------------------------------------------------------
    signal ack_r, rdata_valid : std_logic := '0';
    signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal pb_run, cap_run : std_logic := '0';
    signal pb_burst_reg, cap_burst_reg : unsigned(7 downto 0) := to_unsigned(PB_WPF, 8);
    signal pb_base, cap_base : unsigned(63 downto 0) := (others => '0');
    signal pb_ring, cap_ring : unsigned(31 downto 0) := (others => '0');
    signal pb_period, cap_period : unsigned(31 downto 0) := (others => '0');
    signal pb_underrun_cnt, cap_overrun_cnt : unsigned(31 downto 0) := (others => '0');
    signal fs_count : unsigned(31 downto 0) := (others => '0');
    signal sticky_pb_underrun, sticky_cap_overrun, sticky_axi_err : std_logic := '0';

    ------------------------------------------------------------------
    -- playback fetch (axi domain)
    ------------------------------------------------------------------
    type t_pb_state is (PB_IDLE, PB_ADDR, PB_DATA);
    signal pb_state : t_pb_state := PB_IDLE;
    signal pb_fetch_ptr : unsigned(31 downto 0) := (others => '0');   -- ring offset of next fetch
    signal pb_fetched_total : unsigned(31 downto 0) := (others => '0');
    signal pb_beats : unsigned(8 downto 0) := (others => '0');
    signal pb_beats_left : unsigned(8 downto 0) := (others => '0');
    signal pb_consumed_total, pb_consumed_prev : unsigned(31 downto 0) := (others => '0');
    signal pb_hw_ptr : unsigned(31 downto 0) := (others => '0');
    signal pb_period_acc : unsigned(31 downto 0) := (others => '0');
    signal pb_irq_period : std_logic := '0';

    signal pbf_wr_en   : std_logic;
    signal pbf_wr_full : std_logic;
    signal pbf_wr_count: unsigned(FIFO_DEPTH_BITS downto 0);
    signal pbf_rd_en   : std_logic;
    signal pbf_rd_data : std_logic_vector(DW - 1 downto 0);
    signal pbf_rd_empty: std_logic;
    signal pbf_rd_count: unsigned(FIFO_DEPTH_BITS downto 0);
    signal pbf_wr_rst_n, pbf_rd_rst_n : std_logic;

    ------------------------------------------------------------------
    -- capture write (axi domain)
    ------------------------------------------------------------------
    type t_cap_state is (CAP_IDLE, CAP_ADDR, CAP_DATA, CAP_RESP);
    signal cap_state : t_cap_state := CAP_IDLE;
    signal cap_wr_ptr : unsigned(31 downto 0) := (others => '0');
    signal cap_beats : unsigned(8 downto 0) := (others => '0');
    signal cap_beats_left : unsigned(8 downto 0) := (others => '0');
    signal cap_period_acc : unsigned(31 downto 0) := (others => '0');
    signal cap_irq_period : std_logic := '0';

    signal capf_wr_en   : std_logic;
    signal capf_wr_full : std_logic;
    signal capf_wr_count: unsigned(FIFO_DEPTH_BITS downto 0);
    signal capf_rd_en   : std_logic;
    signal capf_rd_data : std_logic_vector(DW - 1 downto 0);
    signal capf_rd_empty: std_logic;
    signal capf_rd_count: unsigned(FIFO_DEPTH_BITS downto 0);
    signal capf_wr_rst_n, capf_rd_rst_n : std_logic;

    ------------------------------------------------------------------
    -- cross-domain flags
    ------------------------------------------------------------------
    signal pb_run_s1, pb_run_s2, cap_run_s1, cap_run_s2 : std_logic := '0';      -- sys domain
    signal underrun_tog, overrun_tog, fs_tog : std_logic := '0';                 -- sys domain
    signal underrun_a1, underrun_a2, underrun_a3 : std_logic := '0';             -- axi domain
    signal overrun_a1, overrun_a2, overrun_a3 : std_logic := '0';
    signal fs_a1, fs_a2, fs_a3 : std_logic := '0';

    ------------------------------------------------------------------
    -- sys domain frame handling
    ------------------------------------------------------------------
    signal frame_sync_d : std_logic := '0';
    signal mid_frame    : std_logic;
    signal pb_frame     : std_logic_vector(PB_CHANNELS * 32 - 1 downto 0) := (others => '0');
    signal pb_words     : natural range 0 to PB_WPF := 0;
    signal pb_samples_r : std_logic_vector(PB_CHANNELS * SAMPLE_BITS - 1 downto 0) := (others => '0');
    signal cap_frame    : std_logic_vector(CAP_CHANNELS * 32 - 1 downto 0) := (others => '0');
    signal cap_words    : natural range 0 to CAP_WPF := 0;   -- words still to push

    -- burst length limited by the ring end and the 4 KiB PCIe boundary
    function burst_beats(want : unsigned(7 downto 0); ptr : unsigned(31 downto 0);
                         ring : unsigned(31 downto 0); base_lo : unsigned(11 downto 0))
        return unsigned is
        variable w      : unsigned(8 downto 0);
        variable to_end : unsigned(31 downto 0);
        variable to_4k  : unsigned(12 downto 0);
        variable addr_lo: unsigned(12 downto 0);
        variable beats_end, beats_4k : unsigned(31 downto 0);
    begin
        w := '0' & want;
        if w = 0 then
            w := to_unsigned(1, 9);
        elsif w > MAX_BURST then
            w := to_unsigned(MAX_BURST, 9);
        end if;
        -- beats until the end of the ring
        to_end := ring - ptr;
        beats_end := shift_right(to_end, BEAT_BITS);
        if beats_end < w then
            w := resize(beats_end, 9);
        end if;
        -- beats until the next 4 KiB boundary of the bus address
        addr_lo := resize(base_lo, 13) + resize(ptr(11 downto 0), 13);
        to_4k := to_unsigned(4096, 13) - ('0' & addr_lo(11 downto 0));
        beats_4k := resize(shift_right(to_4k, BEAT_BITS), 32);
        if beats_4k < w then
            w := resize(beats_4k, 9);
        end if;
        if w = 0 then
            w := to_unsigned(1, 9);
        end if;
        return w;
    end function;
begin
    assert PB_CHANNELS * 32 mod DW = 0 and PB_WPF >= 1
        report "PB_CHANNELS*32 must be a non-zero multiple of AXI_DATA_WIDTH" severity failure;
    assert CAP_CHANNELS * 32 mod DW = 0 and CAP_WPF >= 1
        report "CAP_CHANNELS*32 must be a non-zero multiple of AXI_DATA_WIDTH" severity failure;

    sb_ack   <= ack_r;
    sb_rdata <= rdata_r;
    pb_samples_o <= pb_samples_r;

    irq_pb_period_o   <= pb_irq_period;
    irq_cap_period_o  <= cap_irq_period;
    irq_pb_underrun_o <= underrun_a2 xor underrun_a3;
    irq_cap_overrun_o <= overrun_a2 xor overrun_a3;

    ------------------------------------------------------------------
    -- FIFOs: held in reset while the direction is stopped
    ------------------------------------------------------------------
    pbf_wr_rst_n  <= axi_rst_n and pb_run;
    pbf_rd_rst_n  <= sys_rst_n and pb_run_s2;
    capf_wr_rst_n <= sys_rst_n and cap_run_s2;
    capf_rd_rst_n <= axi_rst_n and cap_run;

    pb_fifo : entity work.async_fifo
        generic map (WIDTH => DW, DEPTH_BITS => FIFO_DEPTH_BITS)
        port map (
            wr_clk => axi_clk, wr_rst_n => pbf_wr_rst_n,
            wr_en => pbf_wr_en, wr_data => m_axi_rdata, wr_full => pbf_wr_full, wr_count => pbf_wr_count,
            rd_clk => sys_clk, rd_rst_n => pbf_rd_rst_n,
            rd_en => pbf_rd_en, rd_data => pbf_rd_data, rd_empty => pbf_rd_empty, rd_count => pbf_rd_count);

    cap_fifo : entity work.async_fifo
        generic map (WIDTH => DW, DEPTH_BITS => FIFO_DEPTH_BITS)
        port map (
            wr_clk => sys_clk, wr_rst_n => capf_wr_rst_n,
            wr_en => capf_wr_en, wr_data => cap_frame(DW - 1 downto 0), wr_full => capf_wr_full, wr_count => capf_wr_count,
            rd_clk => axi_clk, rd_rst_n => capf_rd_rst_n,
            rd_en => capf_rd_en, rd_data => capf_rd_data, rd_empty => capf_rd_empty, rd_count => capf_rd_count);

    ------------------------------------------------------------------
    -- AXI master: playback reads
    ------------------------------------------------------------------
    m_axi_arid    <= (others => '0');
    m_axi_araddr  <= std_logic_vector(resize(pb_base + resize(pb_fetch_ptr, 64), AXI_ADDR_WIDTH));
    m_axi_arlen   <= std_logic_vector(resize(pb_beats - 1, 8));
    m_axi_arsize  <= AXSIZE;
    m_axi_arburst <= "01";
    m_axi_arvalid <= '1' when pb_state = PB_ADDR else '0';
    m_axi_rready  <= '1' when pb_state = PB_DATA else '0';
    pbf_wr_en     <= '1' when pb_state = PB_DATA and m_axi_rvalid = '1' else '0';

    p_pb : process(axi_clk, axi_rst_n)
        variable delta : unsigned(31 downto 0);
        variable acc   : unsigned(32 downto 0);
        variable hw    : unsigned(32 downto 0);
    begin
        if axi_rst_n = '0' then
            pb_state <= PB_IDLE;
            pb_fetch_ptr <= (others => '0');
            pb_fetched_total <= (others => '0');
            pb_consumed_prev <= (others => '0');
            pb_hw_ptr <= (others => '0');
            pb_period_acc <= (others => '0');
            pb_irq_period <= '0';
            pb_beats <= (others => '0');
            pb_beats_left <= (others => '0');
            sticky_axi_err <= '0';
        elsif rising_edge(axi_clk) then
            pb_irq_period <= '0';
            if pb_run = '0' then
                pb_state <= PB_IDLE;
                pb_fetch_ptr <= (others => '0');
                pb_fetched_total <= (others => '0');
                pb_consumed_prev <= (others => '0');
                pb_hw_ptr <= (others => '0');
                pb_period_acc <= (others => '0');
            else
                case pb_state is
                    when PB_IDLE =>
                        if pb_ring /= 0 and
                           (to_unsigned(FIFO_DEPTH, FIFO_DEPTH_BITS + 1) - pbf_wr_count) >= MAX_BURST then
                            pb_beats <= burst_beats(pb_burst_reg, pb_fetch_ptr, pb_ring, pb_base(11 downto 0));
                            pb_state <= PB_ADDR;
                        end if;
                    when PB_ADDR =>
                        if m_axi_arready = '1' then
                            pb_beats_left <= pb_beats;
                            pb_state <= PB_DATA;
                        end if;
                    when PB_DATA =>
                        if m_axi_rvalid = '1' then
                            if m_axi_rresp(1) = '1' then
                                sticky_axi_err <= '1';
                            end if;
                            -- count per beat, in the same cycle the FIFO takes
                            -- the word, so fetched - in_fifo never steps back
                            pb_fetched_total <= pb_fetched_total + to_unsigned(BEAT_BYTES, 32);
                            pb_beats_left <= pb_beats_left - 1;
                            if m_axi_rlast = '1' or pb_beats_left = 1 then
                                if pb_fetch_ptr + shift_left(resize(pb_beats, 32), BEAT_BITS) >= pb_ring then
                                    pb_fetch_ptr <= (others => '0');
                                else
                                    pb_fetch_ptr <= pb_fetch_ptr + shift_left(resize(pb_beats, 32), BEAT_BITS);
                                end if;
                                pb_state <= PB_IDLE;
                            end if;
                        end if;
                end case;

                -- consumed estimate and derived host pointer / period IRQ
                delta := pb_consumed_total - pb_consumed_prev;
                pb_consumed_prev <= pb_consumed_total;
                hw := ('0' & pb_hw_ptr) + ('0' & delta);
                if hw >= ('0' & pb_ring) then
                    hw := hw - ('0' & pb_ring);
                end if;
                pb_hw_ptr <= hw(31 downto 0);
                acc := ('0' & pb_period_acc) + ('0' & delta);
                if pb_period /= 0 and acc >= ('0' & pb_period) then
                    acc := acc - ('0' & pb_period);
                    pb_irq_period <= '1';
                end if;
                pb_period_acc <= acc(31 downto 0);
            end if;

            -- sticky flags are cleared through STATUS (handled in p_regs via
            -- the clear pulses below); AXI error is set here only.
            if sb_req = '1' and ack_r = '0' and sb_we = '1' and sb_addr(7 downto 2) = "000001" and sb_wdata(6) = '1' then
                sticky_axi_err <= '0';
            end if;
        end if;
    end process;
    pb_consumed_total <= pb_fetched_total - shift_left(resize(pbf_wr_count, 32), BEAT_BITS);

    ------------------------------------------------------------------
    -- AXI master: capture writes
    ------------------------------------------------------------------
    m_axi_awid    <= (others => '0');
    m_axi_awaddr  <= std_logic_vector(resize(cap_base + resize(cap_wr_ptr, 64), AXI_ADDR_WIDTH));
    m_axi_awlen   <= std_logic_vector(resize(cap_beats - 1, 8));
    m_axi_awsize  <= AXSIZE;
    m_axi_awburst <= "01";
    m_axi_awvalid <= '1' when cap_state = CAP_ADDR else '0';
    m_axi_wdata   <= capf_rd_data;
    m_axi_wstrb   <= (others => '1');
    m_axi_wvalid  <= '1' when cap_state = CAP_DATA else '0';
    m_axi_wlast   <= '1' when cap_state = CAP_DATA and cap_beats_left = 1 else '0';
    m_axi_bready  <= '1' when cap_state = CAP_RESP else '0';
    capf_rd_en    <= '1' when cap_state = CAP_DATA and m_axi_wready = '1' else '0';

    p_cap : process(axi_clk, axi_rst_n)
        variable bytes : unsigned(31 downto 0);
        variable acc   : unsigned(32 downto 0);
    begin
        if axi_rst_n = '0' then
            cap_state <= CAP_IDLE;
            cap_wr_ptr <= (others => '0');
            cap_period_acc <= (others => '0');
            cap_irq_period <= '0';
            cap_beats <= (others => '0');
            cap_beats_left <= (others => '0');
        elsif rising_edge(axi_clk) then
            cap_irq_period <= '0';
            if cap_run = '0' then
                cap_state <= CAP_IDLE;
                cap_wr_ptr <= (others => '0');
                cap_period_acc <= (others => '0');
            else
                case cap_state is
                    when CAP_IDLE =>
                        if cap_ring /= 0 and capf_rd_count >= cap_burst_reg and capf_rd_count /= 0 then
                            cap_beats <= burst_beats(cap_burst_reg, cap_wr_ptr, cap_ring, cap_base(11 downto 0));
                            cap_state <= CAP_ADDR;
                        end if;
                    when CAP_ADDR =>
                        if m_axi_awready = '1' then
                            cap_beats_left <= cap_beats;
                            cap_state <= CAP_DATA;
                        end if;
                    when CAP_DATA =>
                        if m_axi_wready = '1' then
                            cap_beats_left <= cap_beats_left - 1;
                            if cap_beats_left = 1 then
                                cap_state <= CAP_RESP;
                            end if;
                        end if;
                    when CAP_RESP =>
                        if m_axi_bvalid = '1' then
                            bytes := shift_left(resize(cap_beats, 32), BEAT_BITS);
                            if cap_wr_ptr + bytes >= cap_ring then
                                cap_wr_ptr <= (others => '0');
                            else
                                cap_wr_ptr <= cap_wr_ptr + bytes;
                            end if;
                            acc := ('0' & cap_period_acc) + ('0' & bytes);
                            if cap_period /= 0 and acc >= ('0' & cap_period) then
                                acc := acc - ('0' & cap_period);
                                cap_irq_period <= '1';
                            end if;
                            cap_period_acc <= acc(31 downto 0);
                            cap_state <= CAP_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- registers
    ------------------------------------------------------------------
    p_regs : process(axi_clk, axi_rst_n)
        variable wr : std_logic;
    begin
        if axi_rst_n = '0' then
            ack_r <= '0';
            rdata_r <= (others => '0');
            pb_run <= '0';
            cap_run <= '0';
            pb_burst_reg <= to_unsigned(PB_WPF, 8);
            cap_burst_reg <= to_unsigned(CAP_WPF, 8);
            pb_base <= (others => '0');
            cap_base <= (others => '0');
            pb_ring <= (others => '0');
            cap_ring <= (others => '0');
            pb_period <= (others => '0');
            cap_period <= (others => '0');
            pb_underrun_cnt <= (others => '0');
            cap_overrun_cnt <= (others => '0');
            fs_count <= (others => '0');
            sticky_pb_underrun <= '0';
            sticky_cap_overrun <= '0';
            underrun_a1 <= '0'; underrun_a2 <= '0'; underrun_a3 <= '0';
            overrun_a1 <= '0';  overrun_a2 <= '0';  overrun_a3 <= '0';
            fs_a1 <= '0'; fs_a2 <= '0'; fs_a3 <= '0';
        elsif rising_edge(axi_clk) then
            underrun_a1 <= underrun_tog; underrun_a2 <= underrun_a1; underrun_a3 <= underrun_a2;
            overrun_a1  <= overrun_tog;  overrun_a2  <= overrun_a1;  overrun_a3  <= overrun_a2;
            fs_a1 <= fs_tog; fs_a2 <= fs_a1; fs_a3 <= fs_a2;
            if underrun_a2 /= underrun_a3 then
                pb_underrun_cnt <= pb_underrun_cnt + 1;
                sticky_pb_underrun <= '1';
            end if;
            if overrun_a2 /= overrun_a3 then
                cap_overrun_cnt <= cap_overrun_cnt + 1;
                sticky_cap_overrun <= '1';
            end if;
            if fs_a2 /= fs_a3 then
                fs_count <= fs_count + 1;
            end if;

            ack_r <= '0';
            if sb_req = '1' and ack_r = '0' then
                ack_r <= '1';
                wr := sb_we and (sb_wstrb(0) or sb_wstrb(1) or sb_wstrb(2) or sb_wstrb(3));
                rdata_r <= (others => '0');
                case sb_addr(7 downto 2) is
                    when "000000" =>   -- CTRL
                        rdata_r(1 downto 0) <= cap_run & pb_run;
                        if wr = '1' then
                            pb_run  <= sb_wdata(0);
                            cap_run <= sb_wdata(1);
                            if sb_wdata(0) = '1' and pb_run = '0' then
                                pb_underrun_cnt <= (others => '0');
                            end if;
                            if sb_wdata(1) = '1' and cap_run = '0' then
                                cap_overrun_cnt <= (others => '0');
                            end if;
                        end if;
                    when "000001" =>   -- STATUS
                        rdata_r(1 downto 0) <= cap_run & pb_run;
                        rdata_r(4) <= sticky_pb_underrun;
                        rdata_r(5) <= sticky_cap_overrun;
                        rdata_r(6) <= sticky_axi_err;
                        if wr = '1' then
                            if sb_wdata(4) = '1' then sticky_pb_underrun <= '0'; end if;
                            if sb_wdata(5) = '1' then sticky_cap_overrun <= '0'; end if;
                        end if;
                    when "000010" =>   -- CAPS
                        rdata_r <= std_logic_vector(to_unsigned(FIFO_DEPTH_BITS, 8)) &
                                   std_logic_vector(to_unsigned(BEAT_BYTES, 8)) &
                                   std_logic_vector(to_unsigned(CAP_CHANNELS, 8)) &
                                   std_logic_vector(to_unsigned(PB_CHANNELS, 8));
                    when "000011" =>   -- BURST
                        rdata_r(15 downto 0) <= std_logic_vector(cap_burst_reg) & std_logic_vector(pb_burst_reg);
                        if wr = '1' then
                            pb_burst_reg  <= unsigned(sb_wdata(7 downto 0));
                            cap_burst_reg <= unsigned(sb_wdata(15 downto 8));
                        end if;
                    when "000100" =>
                        rdata_r <= std_logic_vector(pb_base(31 downto 0));
                        if wr = '1' then pb_base(31 downto 0) <= unsigned(sb_wdata); end if;
                    when "000101" =>
                        rdata_r <= std_logic_vector(pb_base(63 downto 32));
                        if wr = '1' then pb_base(63 downto 32) <= unsigned(sb_wdata); end if;
                    when "000110" =>
                        rdata_r <= std_logic_vector(pb_ring);
                        if wr = '1' then pb_ring <= unsigned(sb_wdata); end if;
                    when "000111" =>
                        rdata_r <= std_logic_vector(pb_period);
                        if wr = '1' then pb_period <= unsigned(sb_wdata); end if;
                    when "001000" =>
                        rdata_r <= std_logic_vector(pb_hw_ptr);
                    when "001001" =>
                        rdata_r <= std_logic_vector(pb_underrun_cnt);
                    when "001100" =>
                        rdata_r <= std_logic_vector(cap_base(31 downto 0));
                        if wr = '1' then cap_base(31 downto 0) <= unsigned(sb_wdata); end if;
                    when "001101" =>
                        rdata_r <= std_logic_vector(cap_base(63 downto 32));
                        if wr = '1' then cap_base(63 downto 32) <= unsigned(sb_wdata); end if;
                    when "001110" =>
                        rdata_r <= std_logic_vector(cap_ring);
                        if wr = '1' then cap_ring <= unsigned(sb_wdata); end if;
                    when "001111" =>
                        rdata_r <= std_logic_vector(cap_period);
                        if wr = '1' then cap_period <= unsigned(sb_wdata); end if;
                    when "010000" =>
                        rdata_r <= std_logic_vector(cap_wr_ptr);
                    when "010001" =>
                        rdata_r <= std_logic_vector(cap_overrun_cnt);
                    when "010100" =>
                        rdata_r <= std_logic_vector(fs_count);
                    when others =>
                        rdata_r <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- sys domain: frame exchange with the AES67 parallel registers
    ------------------------------------------------------------------
    mid_frame <= '1' when frame_sync_d = '1' and frame_sync_i = '0' else '0';
    pbf_rd_en <= '1' when pb_run_s2 = '1' and pbf_rd_empty = '0' and pb_words < PB_WPF else '0';
    capf_wr_en <= '1' when cap_run_s2 = '1' and cap_words /= 0 and capf_wr_full = '0' else '0';

    p_sys : process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            pb_run_s1 <= '0'; pb_run_s2 <= '0';
            cap_run_s1 <= '0'; cap_run_s2 <= '0';
            frame_sync_d <= '0';
            pb_words <= 0;
            pb_frame <= (others => '0');
            pb_samples_r <= (others => '0');
            cap_words <= 0;
            cap_frame <= (others => '0');
            underrun_tog <= '0';
            overrun_tog <= '0';
            fs_tog <= '0';
        elsif rising_edge(sys_clk) then
            pb_run_s1 <= pb_run;   pb_run_s2 <= pb_run_s1;
            cap_run_s1 <= cap_run; cap_run_s2 <= cap_run_s1;
            frame_sync_d <= frame_sync_i;
            if mid_frame = '1' then
                fs_tog <= not fs_tog;
            end if;

            -- playback: assemble the next frame from the FIFO, hand it over
            -- mid-frame
            if pb_run_s2 = '0' then
                pb_words <= 0;
                pb_samples_r <= (others => '0');
            else
                if pbf_rd_en = '1' then
                    pb_frame((pb_words + 1) * DW - 1 downto pb_words * DW) <= pbf_rd_data;
                    pb_words <= pb_words + 1;
                end if;
                if mid_frame = '1' then
                    if pb_words = PB_WPF then
                        for ch in 0 to PB_CHANNELS - 1 loop
                            pb_samples_r((ch + 1) * SAMPLE_BITS - 1 downto ch * SAMPLE_BITS) <=
                                pb_frame(ch * 32 + 31 downto ch * 32 + 32 - SAMPLE_BITS);
                        end loop;
                        pb_words <= 0;
                    else
                        pb_samples_r <= (others => '0');
                        underrun_tog <= not underrun_tog;
                    end if;
                end if;
            end if;

            -- capture: latch the frame mid-frame, stream it into the FIFO
            if cap_run_s2 = '0' then
                cap_words <= 0;
            else
                if capf_wr_en = '1' then
                    cap_frame <= std_logic_vector(shift_right(unsigned(cap_frame), DW));
                    cap_words <= cap_words - 1;
                end if;
                if mid_frame = '1' then
                    -- previous frame not fully pushed (FIFO full): overrun.
                    -- A word pushed in this very cycle still counts as done.
                    if (cap_words /= 0 and capf_wr_en = '0') or
                       (cap_words > 1 and capf_wr_en = '1') then
                        overrun_tog <= not overrun_tog;
                    end if;
                    for ch in 0 to CAP_CHANNELS - 1 loop
                        cap_frame(ch * 32 + 31 downto ch * 32 + 32 - SAMPLE_BITS) <=
                            cap_samples_i((ch + 1) * SAMPLE_BITS - 1 downto ch * SAMPLE_BITS);
                        cap_frame(ch * 32 + 32 - SAMPLE_BITS - 1 downto ch * 32) <= (others => '0');
                    end loop;
                    cap_words <= CAP_WPF;
                end if;
            end if;
        end if;
    end process;
end architecture;
