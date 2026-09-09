-- AXI4 slave -> 32-bit "simple bus" master.
--
-- Sits behind the PCIe-to-AXI bridge (XDMA in AXI Bridge mode, M_AXIB port):
-- every host MMIO access into BAR0 arrives here as an AXI4 read or write of
-- the bridge's native data width (64..256 bits). PCIe hosts only ever issue
-- single-beat 32/64-bit accesses to a register BAR, but the AXI protocol
-- allows narrow and burst transfers, so this slave handles INCR bursts of any
-- length and any transfer size by serialising each beat into one 32-bit
-- simple-bus transaction per active data lane.
--
-- Simple bus (all in the AXI clock domain):
--   sb_req   held high until sb_ack pulses (one cycle); req then drops for at
--            least one cycle before the next transaction.
--   sb_addr  byte address inside BAR0 (low two bits always 0)
--   sb_we    1 = write (sb_wdata/sb_wstrb valid), 0 = read (sb_rdata valid
--            together with sb_ack)
--   sb_err   sampled with sb_ack; turns the AXI response into SLVERR.
--
-- One AXI transaction is processed at a time (writes win when both an AW and
-- an AR are pending). That is plenty for register traffic; bulk data moves
-- through the DMA engine, not through this path.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcie_axi_slave is
    generic (
        AXI_ID_WIDTH   : positive := 4;
        AXI_ADDR_WIDTH : positive := 64;
        AXI_DATA_WIDTH : positive := 128;
        SB_ADDR_WIDTH  : positive := 22
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- AXI4 slave (write address / data / response)
        s_axi_awid    : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        s_axi_awaddr  : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_awlen   : in  std_logic_vector(7 downto 0);
        s_axi_awsize  : in  std_logic_vector(2 downto 0);
        s_axi_awburst : in  std_logic_vector(1 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
        s_axi_wstrb   : in  std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
        s_axi_wlast   : in  std_logic;
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bid     : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        -- AXI4 slave (read address / data)
        s_axi_arid    : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        s_axi_araddr  : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
        s_axi_arlen   : in  std_logic_vector(7 downto 0);
        s_axi_arsize  : in  std_logic_vector(2 downto 0);
        s_axi_arburst : in  std_logic_vector(1 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rid     : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
        s_axi_rdata   : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rlast   : out std_logic;
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -- simple bus master
        sb_addr  : out std_logic_vector(SB_ADDR_WIDTH - 1 downto 0);
        sb_wdata : out std_logic_vector(31 downto 0);
        sb_wstrb : out std_logic_vector(3 downto 0);
        sb_we    : out std_logic;
        sb_req   : out std_logic;
        sb_ack   : in  std_logic;
        sb_rdata : in  std_logic_vector(31 downto 0);
        sb_err   : in  std_logic
    );
end entity;

architecture rtl of pcie_axi_slave is
    constant LANES      : natural := AXI_DATA_WIDTH / 32;
    constant BEAT_BYTES : natural := AXI_DATA_WIDTH / 8;

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
    constant BEAT_BITS : natural := clog2(BEAT_BYTES);   -- address bits inside one beat

    type t_state is (IDLE,
                     WR_DATA, WR_LANE_ISSUE, WR_LANE_WAIT, WR_LANE_NEXT, WR_RESP,
                     RD_LANE_ISSUE, RD_LANE_WAIT, RD_LANE_NEXT, RD_DATA);
    signal state : t_state := IDLE;

    signal id_r      : std_logic_vector(AXI_ID_WIDTH - 1 downto 0) := (others => '0');
    signal addr_r    : unsigned(SB_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal size_r    : unsigned(2 downto 0) := (others => '0');
    signal beats_left: unsigned(7 downto 0) := (others => '0');
    signal err_r     : std_logic := '0';

    signal wdata_r   : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal wstrb_r   : std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0) := (others => '0');
    signal wlast_r   : std_logic := '0';
    signal rdata_r   : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0) := (others => '0');

    signal lane      : natural range 0 to LANES - 1 := 0;
    signal lane_last : natural range 0 to LANES - 1 := 0;

    signal req_r     : std_logic := '0';
    signal we_r      : std_logic := '0';

    -- byte address of the current lane = beat base (addr_r with the in-beat
    -- bits cleared) + lane * 4
    function lane_addr(a : unsigned; l : natural) return unsigned is
        variable base : unsigned(a'range);
    begin
        base := a;
        if BEAT_BITS > 0 then
            base(BEAT_BITS - 1 downto 0) := (others => '0');
        end if;
        return base + to_unsigned(l * 4, a'length);
    end function;

    -- first/last 32-bit lane touched by a beat starting at address a with
    -- transfer size 2**s bytes
    function first_lane(a : unsigned) return natural is
    begin
        if BEAT_BITS <= 2 then
            return 0;
        else
            return to_integer(a(BEAT_BITS - 1 downto 2));
        end if;
    end function;

    function last_lane(a : unsigned; s : unsigned) return natural is
        variable v : unsigned(BEAT_BITS downto 0);
        variable mask : unsigned(BEAT_BITS downto 0);
        variable nbytes : natural;
    begin
        if BEAT_BITS <= 2 then
            return 0;
        end if;
        nbytes := 2 ** to_integer(s);
        if nbytes < 4 then
            nbytes := 4;
        end if;
        if nbytes > BEAT_BYTES then
            nbytes := BEAT_BYTES;
        end if;
        mask := to_unsigned(nbytes - 1, BEAT_BITS + 1);
        v := ('0' & a(BEAT_BITS - 1 downto 0)) or mask;
        return to_integer(v(BEAT_BITS - 1 downto 2));
    end function;

    -- next beat address of an INCR burst: align down to the transfer size,
    -- then add the transfer size
    function next_addr(a : unsigned; s : unsigned) return unsigned is
        variable nbytes : natural;
        variable base : unsigned(a'range);
    begin
        nbytes := 2 ** to_integer(s);
        base := a;
        for i in 0 to a'length - 1 loop
            if i < to_integer(s) then
                base(i) := '0';
            end if;
        end loop;
        return base + to_unsigned(nbytes, a'length);
    end function;
begin
    sb_req   <= req_r;
    sb_we    <= we_r;
    sb_addr  <= std_logic_vector(lane_addr(addr_r, lane));
    sb_wdata <= wdata_r(lane * 32 + 31 downto lane * 32);
    sb_wstrb <= wstrb_r(lane * 4 + 3 downto lane * 4);

    s_axi_awready <= '1' when state = IDLE and s_axi_awvalid = '1' else '0';
    s_axi_arready <= '1' when state = IDLE and s_axi_awvalid = '0' and s_axi_arvalid = '1' else '0';
    s_axi_wready  <= '1' when state = WR_DATA else '0';
    s_axi_bvalid  <= '1' when state = WR_RESP else '0';
    s_axi_bid     <= id_r;
    s_axi_bresp   <= "10" when err_r = '1' else "00";
    s_axi_rvalid  <= '1' when state = RD_DATA else '0';
    s_axi_rid     <= id_r;
    s_axi_rdata   <= rdata_r;
    s_axi_rresp   <= "10" when err_r = '1' else "00";
    s_axi_rlast   <= '1' when state = RD_DATA and beats_left = 0 else '0';

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            req_r <= '0';
            we_r  <= '0';
            err_r <= '0';
            lane  <= 0;
            lane_last <= 0;
            beats_left <= (others => '0');
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    err_r <= '0';
                    if s_axi_awvalid = '1' then
                        id_r   <= s_axi_awid;
                        addr_r <= unsigned(s_axi_awaddr(SB_ADDR_WIDTH - 1 downto 0));
                        size_r <= unsigned(s_axi_awsize);
                        beats_left <= unsigned(s_axi_awlen);
                        state  <= WR_DATA;
                    elsif s_axi_arvalid = '1' then
                        id_r   <= s_axi_arid;
                        addr_r <= unsigned(s_axi_araddr(SB_ADDR_WIDTH - 1 downto 0));
                        size_r <= unsigned(s_axi_arsize);
                        beats_left <= unsigned(s_axi_arlen);
                        rdata_r <= (others => '0');
                        lane   <= first_lane(unsigned(s_axi_araddr(SB_ADDR_WIDTH - 1 downto 0)));
                        lane_last <= last_lane(unsigned(s_axi_araddr(SB_ADDR_WIDTH - 1 downto 0)),
                                               unsigned(s_axi_arsize));
                        state  <= RD_LANE_ISSUE;
                    end if;

                ---------------------------------------------------------
                -- write burst: one simple-bus write per strobed lane
                ---------------------------------------------------------
                when WR_DATA =>
                    if s_axi_wvalid = '1' then
                        wdata_r <= s_axi_wdata;
                        wstrb_r <= s_axi_wstrb;
                        wlast_r <= s_axi_wlast;
                        lane    <= 0;
                        state   <= WR_LANE_ISSUE;
                    end if;

                when WR_LANE_ISSUE =>
                    if wstrb_r(lane * 4 + 3 downto lane * 4) /= "0000" then
                        req_r <= '1';
                        we_r  <= '1';
                        state <= WR_LANE_WAIT;
                    else
                        state <= WR_LANE_NEXT;
                    end if;

                when WR_LANE_WAIT =>
                    if sb_ack = '1' then
                        req_r <= '0';
                        err_r <= err_r or sb_err;
                        state <= WR_LANE_NEXT;
                    end if;

                when WR_LANE_NEXT =>
                    if lane = LANES - 1 then
                        if wlast_r = '1' or beats_left = 0 then
                            state <= WR_RESP;
                        else
                            beats_left <= beats_left - 1;
                            addr_r <= next_addr(addr_r, size_r);
                            state  <= WR_DATA;
                        end if;
                    else
                        lane  <= lane + 1;
                        state <= WR_LANE_ISSUE;
                    end if;

                when WR_RESP =>
                    if s_axi_bready = '1' then
                        state <= IDLE;
                    end if;

                ---------------------------------------------------------
                -- read burst: one simple-bus read per addressed lane
                ---------------------------------------------------------
                when RD_LANE_ISSUE =>
                    req_r <= '1';
                    we_r  <= '0';
                    state <= RD_LANE_WAIT;

                when RD_LANE_WAIT =>
                    if sb_ack = '1' then
                        req_r <= '0';
                        err_r <= err_r or sb_err;
                        rdata_r(lane * 32 + 31 downto lane * 32) <= sb_rdata;
                        state <= RD_LANE_NEXT;
                    end if;

                when RD_LANE_NEXT =>
                    if lane >= lane_last then
                        state <= RD_DATA;
                    else
                        lane  <= lane + 1;
                        state <= RD_LANE_ISSUE;
                    end if;

                when RD_DATA =>
                    if s_axi_rready = '1' then
                        if beats_left = 0 then
                            state <= IDLE;
                        else
                            beats_left <= beats_left - 1;
                            addr_r  <= next_addr(addr_r, size_r);
                            rdata_r <= (others => '0');
                            lane      <= first_lane(next_addr(addr_r, size_r));
                            lane_last <= last_lane(next_addr(addr_r, size_r), size_r);
                            state   <= RD_LANE_ISSUE;
                        end if;
                    end if;
            end case;
        end if;
    end process;
end architecture;
