

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
USE work.system_cfg_pkg.all;
ENTITY sysclk_pll_gen IS
	generic (
		platform : t_platforms := ALTERA; -- ALTERA, GOWIN, LATTICE or XILINX
		clk_in_speed : natural := 50 -- input clock speed in MHz (12/25/50 Altera, 27/50 Gowin, 16 Lattice, 100 Xilinx)
	);
	PORT
	(
        clock_i : IN STD_LOGIC;
        rst_n_i : IN STD_LOGIC;
        sys_clk_125MHz_o : OUT STD_LOGIC;
        mcu_clk_o : OUT STD_LOGIC;
        mcu_clk2_o : OUT STD_LOGIC;
        locked_o : OUT STD_LOGIC

    );
    end sysclk_pll_gen;

architecture rtl of sysclk_pll_gen is
    component gowin_pll_50i is
    port (
        clkin: in std_logic;
        clkout0: out std_logic;
        clkout1: out std_logic;
        lock: out std_logic;
        mdclk: in std_logic
    );
end component;
component lattice_pll_16m
  port (
    CLKI : in std_logic;
    CLKOP : out std_logic;
    CLKOS : out std_logic;
    LOCK : out std_logic
  );
end component;
component sysclks_altpll_50m_in
  port (
    areset : in STD_LOGIC;
    inclk0 : in STD_LOGIC;
    c0 : out STD_LOGIC;
    c1 : out STD_LOGIC;
    c2 : out STD_LOGIC;
    locked : out STD_LOGIC
  );
end component;
component sysclks_altpll_12m_in
  port (
    areset : in STD_LOGIC;
    inclk0 : in STD_LOGIC;
    c0 : out STD_LOGIC;
    c1 : out STD_LOGIC;
    c2 : out STD_LOGIC;
    locked : out STD_LOGIC
  );
end component;
component gowin_pll_27i_125o
  port (
    clkout : out std_logic;
    reset : in std_logic;
    clkin : in std_logic;
    lock_o : out std_logic
  );
  
end component;
component altpll_25m
  port (
    inclk0 : in STD_LOGIC;
    c0 : out STD_LOGIC;
    c1 : out STD_LOGIC;
    locked : out STD_LOGIC
  );
end component;
-- Xilinx UltraScale+ primitives, declared as components so this file stays
-- vendor-library free (Vivado binds them to unisim by name).
component MMCME4_BASE
  generic (
    BANDWIDTH        : string  := "OPTIMIZED";
    CLKFBOUT_MULT_F  : real    := 5.0;
    CLKFBOUT_PHASE   : real    := 0.0;
    CLKIN1_PERIOD    : real    := 0.0;
    CLKOUT0_DIVIDE_F : real    := 1.0;
    CLKOUT0_DUTY_CYCLE : real  := 0.5;
    CLKOUT0_PHASE    : real    := 0.0;
    CLKOUT1_DIVIDE   : integer := 1;
    CLKOUT1_DUTY_CYCLE : real  := 0.5;
    CLKOUT1_PHASE    : real    := 0.0;
    CLKOUT2_DIVIDE   : integer := 1;
    CLKOUT2_DUTY_CYCLE : real  := 0.5;
    CLKOUT2_PHASE    : real    := 0.0;
    CLKOUT3_DIVIDE   : integer := 1;
    CLKOUT3_DUTY_CYCLE : real  := 0.5;
    CLKOUT3_PHASE    : real    := 0.0;
    CLKOUT4_CASCADE  : string  := "FALSE";
    CLKOUT4_DIVIDE   : integer := 1;
    CLKOUT4_DUTY_CYCLE : real  := 0.5;
    CLKOUT4_PHASE    : real    := 0.0;
    CLKOUT5_DIVIDE   : integer := 1;
    CLKOUT5_DUTY_CYCLE : real  := 0.5;
    CLKOUT5_PHASE    : real    := 0.0;
    CLKOUT6_DIVIDE   : integer := 1;
    CLKOUT6_DUTY_CYCLE : real  := 0.5;
    CLKOUT6_PHASE    : real    := 0.0;
    DIVCLK_DIVIDE    : integer := 1;
    IS_CLKFBIN_INVERTED : bit  := '0';
    IS_CLKIN1_INVERTED  : bit  := '0';
    IS_PWRDWN_INVERTED  : bit  := '0';
    IS_RST_INVERTED     : bit  := '0';
    REF_JITTER1      : real    := 0.0;
    STARTUP_WAIT     : string  := "FALSE"
  );
  port (
    CLKFBOUT  : out std_logic;
    CLKFBOUTB : out std_logic;
    CLKOUT0   : out std_logic;
    CLKOUT0B  : out std_logic;
    CLKOUT1   : out std_logic;
    CLKOUT1B  : out std_logic;
    CLKOUT2   : out std_logic;
    CLKOUT2B  : out std_logic;
    CLKOUT3   : out std_logic;
    CLKOUT3B  : out std_logic;
    CLKOUT4   : out std_logic;
    CLKOUT5   : out std_logic;
    CLKOUT6   : out std_logic;
    LOCKED    : out std_logic;
    CLKFBIN   : in  std_logic;
    CLKIN1    : in  std_logic;
    PWRDWN    : in  std_logic;
    RST       : in  std_logic
  );
end component;
component BUFG
  port (
    I : in  std_logic;
    O : out std_logic
  );
end component;
signal sys_clk_locked : std_logic;
signal xil_clkfb, xil_clkfb_buf : std_logic;
signal xil_clk125_raw, xil_clk75_raw, xil_clk75_90_raw : std_logic;
begin
-- system clocks
sysclkgen50: if (platform = ALTERA and clk_in_speed = 50) generate
sysclks_altpll_50m_in_inst : sysclks_altpll_50m_in PORT MAP (
		areset	 => not rst_n_i,
		inclk0	 => clock_i,
		c0	 => sys_clk_125MHz_o,
		c1 	 => mcu_clk_o,
		c2 	 => mcu_clk2_o,
		locked	 => sys_clk_locked
	);

end generate;
sysclkgen25: if (platform = ALTERA and clk_in_speed = 25) generate
sysclks_altpll_25m_in_inst : altpll_25m
  port map (
    inclk0 => clock_i,
    c0 => sys_clk_125MHz_o,
    c1 => mcu_clk_o,
    locked => sys_clk_locked
  );


end generate;
sysclkgen12: if (platform = ALTERA and clk_in_speed = 12) generate
sysclks_altpll_12m_in_inst : sysclks_altpll_12m_in PORT MAP (
		areset	 => not rst_n_i,
		inclk0	 => clock_i,
		c0	 => sys_clk_125MHz_o,
		c1 	 => mcu_clk_o,
		c2 	 => mcu_clk2_o,
		locked	 => sys_clk_locked
	);

end generate;
sysclkgen27: if (platform = GOWIN and clk_in_speed = 27) generate
gowin_pll_27i_125o_inst: gowin_pll_27i_125o
 port map(
	clkout => sys_clk_125MHz_o,
	reset => not rst_n_i,
	clkin => clock_i,
	lock_o => sys_clk_locked
);
end generate;


sysclkgen50_gw: if (platform = GOWIN and clk_in_speed = 50) generate
	gowin_pll_50i_inst: gowin_pll_50i
	 port map(
		clkin => clock_i,
		clkout0 => sys_clk_125MHz_o,
		lock => sys_clk_locked,
		mdclk => clock_i
	);
end generate;
sysclkgen16_lat : if (platform = LATTICE and clk_in_speed = 16) generate
	lattice_pll_16m_inst: lattice_pll_16m
	 port map(
		CLKI => clock_i,
		CLKOP => sys_clk_125MHz_o,
		CLKOS => mcu_clk_o,
		LOCK => sys_clk_locked
	);

end generate;

-- Xilinx UltraScale+ (Alibaba KU3P card): 100 MHz LVDS oscillator (already
-- through an IBUFDS + BUFG in the board top). MMCM VCO = 100 MHz * 15 =
-- 1500 MHz, inside the 800..1600 MHz range of the -1 speed grade:
--   CLKOUT0 = 1500 / 12 = 125 MHz  (sys_clk_125MHz, wallclock/NCO domain)
--   CLKOUT1 = 1500 / 20 = 75 MHz   (mcu_clk, LiteX aes67_bridge clk_sys)
--   CLKOUT2 = 75 MHz, 90 deg       (mcu_clk2, unused here, kept for symmetry)
sysclkgen100_xil : if (platform = XILINX and clk_in_speed = 100) generate
    mmcm_inst : MMCME4_BASE
      generic map (
        BANDWIDTH        => "OPTIMIZED",
        CLKFBOUT_MULT_F  => 15.0,
        CLKFBOUT_PHASE   => 0.0,
        CLKIN1_PERIOD    => 10.0,
        CLKOUT0_DIVIDE_F => 12.0,
        CLKOUT1_DIVIDE   => 20,
        CLKOUT2_DIVIDE   => 20,
        CLKOUT2_PHASE    => 90.0,
        DIVCLK_DIVIDE    => 1,
        REF_JITTER1      => 0.010,
        STARTUP_WAIT     => "FALSE"
      )
      port map (
        CLKFBOUT  => xil_clkfb,
        CLKFBOUTB => open,
        CLKOUT0   => xil_clk125_raw,
        CLKOUT0B  => open,
        CLKOUT1   => xil_clk75_raw,
        CLKOUT1B  => open,
        CLKOUT2   => xil_clk75_90_raw,
        CLKOUT2B  => open,
        CLKOUT3   => open,
        CLKOUT3B  => open,
        CLKOUT4   => open,
        CLKOUT5   => open,
        CLKOUT6   => open,
        LOCKED    => sys_clk_locked,
        CLKFBIN   => xil_clkfb_buf,
        CLKIN1    => clock_i,
        PWRDWN    => '0',
        RST       => not rst_n_i
      );
    bufg_fb  : BUFG port map (I => xil_clkfb,        O => xil_clkfb_buf);
    bufg_125 : BUFG port map (I => xil_clk125_raw,   O => sys_clk_125MHz_o);
    bufg_75  : BUFG port map (I => xil_clk75_raw,    O => mcu_clk_o);
    bufg_75b : BUFG port map (I => xil_clk75_90_raw, O => mcu_clk2_o);
end generate;

locked_o <= sys_clk_locked;
end architecture;
