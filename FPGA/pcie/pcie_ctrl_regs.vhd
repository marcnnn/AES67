-- Board / interrupt control registers of the PCIe AES67 card (BAR0 + 0x200000).
--
-- Register map (byte offsets, 32-bit):
--   0x00 ID          RO  0xAE670001
--   0x04 VERSION     RO  gateware version (generic)
--   0x08 IRQ_STATUS  R/W1C
--                        bit0 eth_buf RX-ready (level, from the LiteX bridge;
--                             cleared by servicing eth_buf, not by writing)
--                        bit1 playback period elapsed        (W1C)
--                        bit2 capture period elapsed         (W1C)
--                        bit3 playback FIFO underrun         (W1C)
--                        bit4 capture FIFO overrun           (W1C)
--   0x0C IRQ_ENABLE  RW  same bit layout; a set bit lets the source raise
--                        the PCIe interrupt (usr_irq_req of the XDMA bridge)
--   0x10 LEDS        RW  bit7..0 -> board LEDs (see board top for the map)
--   0x14 SFP_STATUS  RO  bit0 MOD_ABS, bit1 TX_FAULT, bit2 LOS,
--                        bit31..16 PCS/PMA status_vector
--   0x18 PCS_CTRL    RW  bit4..0 PCS configuration_vector (reset 0x10 = AN
--                        enabled), bit8 AN restart (self clearing), bit9 PCS
--                        reset, bit10 SFP TX disable
--   0x1C LINK_STATUS RO  bit0 PCIe user_lnk_up, bit1 system MMCM locked,
--                        bit2 PCS resetdone, bit3 PCS MMCM locked,
--                        bit4 PCS AN interrupt, bit5 MAC link up
--   0x20 SCRATCH     RW
--
-- Interrupt delivery follows the XDMA usr_irq_req / usr_irq_ack protocol:
-- request is asserted while any enabled source is pending, held until the
-- bridge acknowledges it, released, and re-asserted (after a short cool-down)
-- if sources are still pending. The host ISR reads IRQ_STATUS, services the
-- eth_buf datapath (which drops bit0) and writes the W1C bits back.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcie_ctrl_regs is
    generic (
        VERSION : std_logic_vector(31 downto 0) := x"00010000"
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- simple bus slave (byte offset inside the 1 MiB region)
        sb_addr  : in  std_logic_vector(7 downto 0);
        sb_wdata : in  std_logic_vector(31 downto 0);
        sb_wstrb : in  std_logic_vector(3 downto 0);
        sb_we    : in  std_logic;
        sb_req   : in  std_logic;
        sb_ack   : out std_logic;
        sb_rdata : out std_logic_vector(31 downto 0);

        -- interrupt sources
        eth_buf_irq_i   : in std_logic;   -- level, foreign clock domain
        pb_period_i     : in std_logic;   -- pulses, clk domain
        cap_period_i    : in std_logic;
        pb_underrun_i   : in std_logic;
        cap_overrun_i   : in std_logic;
        usr_irq_req_o   : out std_logic;
        usr_irq_ack_i   : in  std_logic;

        -- board I/O
        leds_o          : out std_logic_vector(7 downto 0);
        sfp_mod_abs_i   : in  std_logic;
        sfp_tx_fault_i  : in  std_logic;
        sfp_los_i       : in  std_logic;
        sfp_tx_disable_o: out std_logic;
        pcs_status_vector_i : in  std_logic_vector(15 downto 0);
        pcs_configuration_vector_o : out std_logic_vector(4 downto 0);
        pcs_an_restart_o: out std_logic;
        pcs_reset_o     : out std_logic;
        pcs_resetdone_i : in  std_logic;
        pcs_mmcm_locked_i : in std_logic;
        pcs_an_interrupt_i : in std_logic;
        user_lnk_up_i   : in  std_logic;
        sys_pll_locked_i: in  std_logic;
        mac_link_up_i   : in  std_logic
    );
end entity;

architecture rtl of pcie_ctrl_regs is
    constant ID_VALUE : std_logic_vector(31 downto 0) := x"AE670001";

    signal ack_r      : std_logic := '0';
    signal rdata_r    : std_logic_vector(31 downto 0) := (others => '0');

    signal irq_pending : std_logic_vector(4 downto 1) := (others => '0');
    signal irq_enable  : std_logic_vector(4 downto 0) := (others => '0');
    signal leds_r      : std_logic_vector(7 downto 0) := (others => '0');
    -- reset: auto-negotiation enabled (bit4), everything else off
    signal pcs_ctrl_r  : std_logic_vector(10 downto 0) := (4 => '1', others => '0');
    signal an_restart_r: std_logic := '0';
    signal scratch_r   : std_logic_vector(31 downto 0) := (others => '0');

    -- synchronisers for foreign-domain / asynchronous inputs
    signal eth_irq_s1, eth_irq_s2 : std_logic := '0';
    signal mod_abs_s1, mod_abs_s2 : std_logic := '0';
    signal tx_fault_s1, tx_fault_s2 : std_logic := '0';
    signal los_s1, los_s2 : std_logic := '0';
    signal status_s1, status_s2 : std_logic_vector(15 downto 0) := (others => '0');
    signal resetdone_s1, resetdone_s2 : std_logic := '0';
    signal pcs_locked_s1, pcs_locked_s2 : std_logic := '0';
    signal an_int_s1, an_int_s2 : std_logic := '0';
    signal lnk_up_s1, lnk_up_s2 : std_logic := '0';
    signal sys_locked_s1, sys_locked_s2 : std_logic := '0';
    signal mac_up_s1, mac_up_s2 : std_logic := '0';

    signal irq_status  : std_logic_vector(4 downto 0);
    signal irq_active  : std_logic;

    type t_irq_state is (IRQ_IDLE, IRQ_REQ, IRQ_COOLDOWN);
    signal irq_state   : t_irq_state := IRQ_IDLE;
    signal irq_req_r   : std_logic := '0';
    signal irq_timer   : unsigned(15 downto 0) := (others => '0');
begin
    sb_ack   <= ack_r;
    sb_rdata <= rdata_r;

    leds_o           <= leds_r;
    pcs_configuration_vector_o <= pcs_ctrl_r(4 downto 0);
    pcs_an_restart_o <= an_restart_r;
    pcs_reset_o      <= pcs_ctrl_r(9);
    sfp_tx_disable_o <= pcs_ctrl_r(10);
    usr_irq_req_o    <= irq_req_r;

    irq_status <= irq_pending & eth_irq_s2;
    irq_active <= '1' when (irq_status and irq_enable) /= "00000" else '0';

    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            eth_irq_s1 <= eth_buf_irq_i;   eth_irq_s2 <= eth_irq_s1;
            mod_abs_s1 <= sfp_mod_abs_i;   mod_abs_s2 <= mod_abs_s1;
            tx_fault_s1 <= sfp_tx_fault_i; tx_fault_s2 <= tx_fault_s1;
            los_s1 <= sfp_los_i;           los_s2 <= los_s1;
            status_s1 <= pcs_status_vector_i; status_s2 <= status_s1;
            resetdone_s1 <= pcs_resetdone_i; resetdone_s2 <= resetdone_s1;
            pcs_locked_s1 <= pcs_mmcm_locked_i; pcs_locked_s2 <= pcs_locked_s1;
            an_int_s1 <= pcs_an_interrupt_i; an_int_s2 <= an_int_s1;
            lnk_up_s1 <= user_lnk_up_i;    lnk_up_s2 <= lnk_up_s1;
            sys_locked_s1 <= sys_pll_locked_i; sys_locked_s2 <= sys_locked_s1;
            mac_up_s1 <= mac_link_up_i;    mac_up_s2 <= mac_up_s1;
        end if;
    end process;

    p_regs : process(clk, rst_n)
        variable wr : std_logic;
    begin
        if rst_n = '0' then
            ack_r       <= '0';
            rdata_r     <= (others => '0');
            irq_pending <= (others => '0');
            irq_enable  <= (others => '0');
            leds_r      <= (others => '0');
            pcs_ctrl_r  <= (4 => '1', others => '0');
            an_restart_r<= '0';
            scratch_r   <= (others => '0');
        elsif rising_edge(clk) then
            an_restart_r <= '0';

            -- latch new events (sticky until cleared by the host)
            if pb_period_i = '1'   then irq_pending(1) <= '1'; end if;
            if cap_period_i = '1'  then irq_pending(2) <= '1'; end if;
            if pb_underrun_i = '1' then irq_pending(3) <= '1'; end if;
            if cap_overrun_i = '1' then irq_pending(4) <= '1'; end if;

            ack_r <= '0';
            if sb_req = '1' and ack_r = '0' then
                ack_r <= '1';
                wr := sb_we and (sb_wstrb(0) or sb_wstrb(1) or sb_wstrb(2) or sb_wstrb(3));
                case sb_addr(7 downto 2) is
                    when "000000" => rdata_r <= ID_VALUE;
                    when "000001" => rdata_r <= VERSION;
                    when "000010" =>
                        rdata_r <= (31 downto 5 => '0') & irq_status;
                        if wr = '1' then
                            for i in 1 to 4 loop
                                if sb_wdata(i) = '1' then irq_pending(i) <= '0'; end if;
                            end loop;
                        end if;
                    when "000011" =>
                        rdata_r <= (31 downto 5 => '0') & irq_enable;
                        if wr = '1' then irq_enable <= sb_wdata(4 downto 0); end if;
                    when "000100" =>
                        rdata_r <= (31 downto 8 => '0') & leds_r;
                        if wr = '1' then leds_r <= sb_wdata(7 downto 0); end if;
                    when "000101" =>
                        rdata_r <= status_s2 & "0000000000000" & los_s2 & tx_fault_s2 & mod_abs_s2;
                    when "000110" =>
                        rdata_r <= (31 downto 11 => '0') & pcs_ctrl_r;
                        if wr = '1' then
                            pcs_ctrl_r(4 downto 0) <= sb_wdata(4 downto 0);
                            pcs_ctrl_r(10 downto 9) <= sb_wdata(10 downto 9);
                            an_restart_r <= sb_wdata(8);
                        end if;
                    when "000111" =>
                        rdata_r <= (31 downto 6 => '0') & mac_up_s2 & an_int_s2 & pcs_locked_s2 & resetdone_s2 & sys_locked_s2 & lnk_up_s2;
                    when "001000" =>
                        rdata_r <= scratch_r;
                        if wr = '1' then scratch_r <= sb_wdata; end if;
                    when others =>
                        rdata_r <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    -- usr_irq_req / usr_irq_ack handshake towards the XDMA bridge
    p_irq : process(clk, rst_n)
    begin
        if rst_n = '0' then
            irq_state <= IRQ_IDLE;
            irq_req_r <= '0';
            irq_timer <= (others => '0');
        elsif rising_edge(clk) then
            case irq_state is
                when IRQ_IDLE =>
                    if irq_active = '1' then
                        irq_req_r <= '1';
                        irq_timer <= (others => '0');
                        irq_state <= IRQ_REQ;
                    end if;
                when IRQ_REQ =>
                    irq_timer <= irq_timer + 1;
                    -- release on ack, or give up if the bridge never answers
                    -- (interrupts disabled on the host) so we can retry later
                    if usr_irq_ack_i = '1' or irq_timer = (irq_timer'range => '1') then
                        irq_req_r <= '0';
                        irq_timer <= (others => '0');
                        irq_state <= IRQ_COOLDOWN;
                    end if;
                when IRQ_COOLDOWN =>
                    irq_timer <= irq_timer + 1;
                    if irq_timer = 32 then
                        irq_state <= IRQ_IDLE;
                    end if;
            end case;
        end if;
    end process;
end architecture;
