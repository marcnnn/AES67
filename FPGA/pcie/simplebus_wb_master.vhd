-- Simple bus (PCIe AXI clock) -> Wishbone master (LiteX aes67_bridge clock).
--
-- This is the PCIe counterpart of LiteX's spibone/uartbone: the *only*
-- Wishbone master in front of the aes67_bridge slave. Every host register
-- access is one Wishbone classic cycle. The two sides run on unrelated clocks
-- (PCIe user clock vs. the MMCM-derived 75 MHz mcu clock), so the request and
-- the response cross with toggle handshakes; the payload registers are stable
-- for the whole handshake and are sampled only after the toggle has been
-- synchronised (constrain the two clocks as asynchronous groups).
--
-- Address mapping: the host sees the aes67_bridge window at BAR0 offset 0, so
-- the Wishbone byte address is WB_BASE + sb_addr (the LiteX bridge decodes
-- its slaves against the full 0x90000000-based address) and wb_adr carries
-- the word address (byte address >> 2), matching what spibone emits.
--
-- A watchdog terminates a cycle nobody answers (unmapped address) with an
-- error instead of hanging the PCIe read forever and freezing the host.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity simplebus_wb_master is
    generic (
        WB_BASE       : std_logic_vector(31 downto 0) := x"90000000";
        SB_ADDR_WIDTH : positive := 22;
        TIMEOUT_BITS  : positive := 12
    );
    port (
        -- simple bus slave side (sb_clk domain)
        sb_clk   : in  std_logic;
        sb_rst_n : in  std_logic;
        sb_addr  : in  std_logic_vector(SB_ADDR_WIDTH - 1 downto 0);
        sb_wdata : in  std_logic_vector(31 downto 0);
        sb_wstrb : in  std_logic_vector(3 downto 0);
        sb_we    : in  std_logic;
        sb_req   : in  std_logic;
        sb_ack   : out std_logic;
        sb_rdata : out std_logic_vector(31 downto 0);
        sb_err   : out std_logic;

        -- Wishbone master side (wb_clk domain)
        wb_clk   : in  std_logic;
        wb_rst_n : in  std_logic;
        wb_adr   : out std_logic_vector(29 downto 0);
        wb_dat_w : out std_logic_vector(31 downto 0);
        wb_dat_r : in  std_logic_vector(31 downto 0);
        wb_sel   : out std_logic_vector(3 downto 0);
        wb_cyc   : out std_logic;
        wb_stb   : out std_logic;
        wb_we    : out std_logic;
        wb_ack   : in  std_logic;
        wb_err   : in  std_logic;
        wb_cti   : out std_logic_vector(2 downto 0);
        wb_bte   : out std_logic_vector(1 downto 0)
    );
end entity;

architecture rtl of simplebus_wb_master is
    -- request payload, written by the sb side, read by the wb side
    signal req_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal req_data  : std_logic_vector(31 downto 0) := (others => '0');
    signal req_sel   : std_logic_vector(3 downto 0) := (others => '0');
    signal req_we    : std_logic := '0';
    signal req_tog   : std_logic := '0';
    -- response payload, written by the wb side, read by the sb side
    signal rsp_data  : std_logic_vector(31 downto 0) := (others => '0');
    signal rsp_err   : std_logic := '0';
    signal rsp_tog   : std_logic := '0';

    -- synchronisers
    signal req_tog_w1, req_tog_w2, req_tog_w3 : std_logic := '0';
    signal rsp_tog_s1, rsp_tog_s2, rsp_tog_s3 : std_logic := '0';

    signal busy   : std_logic := '0';
    signal ack_r  : std_logic := '0';

    signal cyc_r  : std_logic := '0';
    signal timeout_cnt : unsigned(TIMEOUT_BITS - 1 downto 0) := (others => '0');
begin
    ----------------------------------------------------------------
    -- simple bus side
    ----------------------------------------------------------------
    sb_ack   <= ack_r;
    sb_rdata <= rsp_data;
    sb_err   <= rsp_err;

    p_sb : process(sb_clk, sb_rst_n)
    begin
        if sb_rst_n = '0' then
            busy    <= '0';
            ack_r   <= '0';
            req_tog <= '0';
            rsp_tog_s1 <= '0';
            rsp_tog_s2 <= '0';
            rsp_tog_s3 <= '0';
        elsif rising_edge(sb_clk) then
            rsp_tog_s1 <= rsp_tog;
            rsp_tog_s2 <= rsp_tog_s1;
            rsp_tog_s3 <= rsp_tog_s2;
            ack_r <= '0';
            if busy = '0' then
                -- do not re-accept the request that is being acknowledged
                if sb_req = '1' and ack_r = '0' then
                    req_addr <= std_logic_vector(unsigned(WB_BASE) + resize(unsigned(sb_addr), 32));
                    req_data <= sb_wdata;
                    req_sel  <= sb_wstrb;
                    req_we   <= sb_we;
                    req_tog  <= not req_tog;
                    busy     <= '1';
                end if;
            else
                if rsp_tog_s2 /= rsp_tog_s3 then
                    -- response toggle seen: rsp_data/rsp_err were written
                    -- before the toggle and have been stable since.
                    ack_r <= '1';
                    busy  <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Wishbone side
    ----------------------------------------------------------------
    wb_adr   <= req_addr(31 downto 2);
    wb_dat_w <= req_data;
    wb_sel   <= req_sel;
    wb_we    <= req_we;
    wb_cyc   <= cyc_r;
    wb_stb   <= cyc_r;
    wb_cti   <= "000";
    wb_bte   <= "00";

    p_wb : process(wb_clk, wb_rst_n)
    begin
        if wb_rst_n = '0' then
            cyc_r   <= '0';
            rsp_tog <= '0';
            rsp_err <= '0';
            req_tog_w1 <= '0';
            req_tog_w2 <= '0';
            req_tog_w3 <= '0';
            timeout_cnt <= (others => '0');
        elsif rising_edge(wb_clk) then
            req_tog_w1 <= req_tog;
            req_tog_w2 <= req_tog_w1;
            req_tog_w3 <= req_tog_w2;
            if cyc_r = '0' then
                if req_tog_w2 /= req_tog_w3 then
                    cyc_r <= '1';
                    timeout_cnt <= (others => '0');
                end if;
            else
                timeout_cnt <= timeout_cnt + 1;
                if wb_ack = '1' or wb_err = '1' then
                    cyc_r    <= '0';
                    rsp_data <= wb_dat_r;
                    rsp_err  <= wb_err;
                    rsp_tog  <= not rsp_tog;
                elsif timeout_cnt = (timeout_cnt'range => '1') then
                    cyc_r    <= '0';
                    rsp_data <= x"DEADBEEF";
                    rsp_err  <= '1';
                    rsp_tog  <= not rsp_tog;
                end if;
            end if;
        end if;
    end process;
end architecture;
