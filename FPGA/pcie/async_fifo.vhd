-- Vendor-agnostic dual-clock FIFO (gray-coded pointers, 2-FF synchronisers).
--
-- Used by the PCIe audio DMA engine to move sample words between the PCIe
-- AXI clock domain and the 125 MHz AES67 data-plane clock. DEPTH must be a
-- power of two. Occupancy counts are provided per side so the writer can
-- reserve space for a whole burst before issuing it and the reader can wait
-- for a whole burst before draining. Both counts are conservative (the write
-- side under-estimates free space, the read side under-estimates fill).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity async_fifo is
    generic (
        WIDTH      : positive := 128;
        DEPTH_BITS : positive := 6      -- 2**DEPTH_BITS entries
    );
    port (
        -- write side
        wr_clk     : in  std_logic;
        wr_rst_n   : in  std_logic;
        wr_en      : in  std_logic;
        wr_data    : in  std_logic_vector(WIDTH - 1 downto 0);
        wr_full    : out std_logic;
        wr_count   : out unsigned(DEPTH_BITS downto 0);   -- entries used (writer view)
        -- read side
        rd_clk     : in  std_logic;
        rd_rst_n   : in  std_logic;
        rd_en      : in  std_logic;
        rd_data    : out std_logic_vector(WIDTH - 1 downto 0);
        rd_empty   : out std_logic;
        rd_count   : out unsigned(DEPTH_BITS downto 0)    -- entries available (reader view)
    );
end entity;

architecture rtl of async_fifo is
    constant DEPTH : natural := 2 ** DEPTH_BITS;
    type t_mem is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
    signal mem : t_mem;

    -- pointers carry one extra bit to distinguish full from empty
    signal wr_ptr_bin, rd_ptr_bin : unsigned(DEPTH_BITS downto 0) := (others => '0');
    signal wr_ptr_gray, rd_ptr_gray : std_logic_vector(DEPTH_BITS downto 0) := (others => '0');
    -- synchronised copies of the other side's gray pointer
    signal rd_ptr_gray_w1, rd_ptr_gray_w2 : std_logic_vector(DEPTH_BITS downto 0) := (others => '0');
    signal wr_ptr_gray_r1, wr_ptr_gray_r2 : std_logic_vector(DEPTH_BITS downto 0) := (others => '0');

    signal full_i, empty_i : std_logic;

    function bin2gray(b : unsigned) return std_logic_vector is
        variable g : std_logic_vector(b'range);
    begin
        g := std_logic_vector(b xor ('0' & b(b'high downto b'low + 1)));
        return g;
    end function;

    function gray2bin(g : std_logic_vector) return unsigned is
        variable b : unsigned(g'range);
    begin
        b(g'high) := g(g'high);
        for i in g'high - 1 downto g'low loop
            b(i) := b(i + 1) xor g(i);
        end loop;
        return b;
    end function;

    signal rd_ptr_bin_w : unsigned(DEPTH_BITS downto 0);
    signal wr_ptr_bin_r : unsigned(DEPTH_BITS downto 0);
begin
    ----------------------------------------------------------------
    -- write side
    ----------------------------------------------------------------
    rd_ptr_bin_w <= gray2bin(rd_ptr_gray_w2);
    full_i  <= '1' when (wr_ptr_bin(DEPTH_BITS) /= rd_ptr_bin_w(DEPTH_BITS)) and
                        (wr_ptr_bin(DEPTH_BITS - 1 downto 0) = rd_ptr_bin_w(DEPTH_BITS - 1 downto 0))
               else '0';
    wr_full  <= full_i;
    wr_count <= wr_ptr_bin - rd_ptr_bin_w;

    p_wr : process(wr_clk, wr_rst_n)
    begin
        if wr_rst_n = '0' then
            wr_ptr_bin  <= (others => '0');
            wr_ptr_gray <= (others => '0');
            rd_ptr_gray_w1 <= (others => '0');
            rd_ptr_gray_w2 <= (others => '0');
        elsif rising_edge(wr_clk) then
            rd_ptr_gray_w1 <= rd_ptr_gray;
            rd_ptr_gray_w2 <= rd_ptr_gray_w1;
            if wr_en = '1' and full_i = '0' then
                wr_ptr_bin  <= wr_ptr_bin + 1;
                wr_ptr_gray <= bin2gray(wr_ptr_bin + 1);
            end if;
        end if;
    end process;

    p_mem : process(wr_clk)
    begin
        if rising_edge(wr_clk) then
            if wr_en = '1' and full_i = '0' then
                mem(to_integer(wr_ptr_bin(DEPTH_BITS - 1 downto 0))) <= wr_data;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- read side
    ----------------------------------------------------------------
    wr_ptr_bin_r <= gray2bin(wr_ptr_gray_r2);
    empty_i  <= '1' when wr_ptr_gray_r2 = rd_ptr_gray else '0';
    rd_empty <= empty_i;
    rd_count <= wr_ptr_bin_r - rd_ptr_bin;
    rd_data  <= mem(to_integer(rd_ptr_bin(DEPTH_BITS - 1 downto 0)));

    p_rd : process(rd_clk, rd_rst_n)
    begin
        if rd_rst_n = '0' then
            rd_ptr_bin  <= (others => '0');
            rd_ptr_gray <= (others => '0');
            wr_ptr_gray_r1 <= (others => '0');
            wr_ptr_gray_r2 <= (others => '0');
        elsif rising_edge(rd_clk) then
            wr_ptr_gray_r1 <= wr_ptr_gray;
            wr_ptr_gray_r2 <= wr_ptr_gray_r1;
            if rd_en = '1' and empty_i = '0' then
                rd_ptr_bin  <= rd_ptr_bin + 1;
                rd_ptr_gray <= bin2gray(rd_ptr_bin + 1);
            end if;
        end if;
    end process;
end architecture;
