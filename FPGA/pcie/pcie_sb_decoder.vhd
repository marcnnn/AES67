-- BAR0 address decoder for the simple bus.
--
--   BAR0 offset            region
--   0x000000 - 0x0FFFFF    LiteX aes67_bridge Wishbone window (byte address
--                          0x90000000 + offset: eth_buf, stream RAMs, CSRs)
--   0x100000 - 0x1FFFFF    PCIe audio DMA engine registers (pcie_audio_dma)
--   0x200000 - 0x2FFFFF    board / IRQ control registers (pcie_ctrl_regs)
--   0x300000 - 0x3FFFFF    unmapped: acknowledged with an error
--
-- The region is taken from sb_addr(21 downto 20), which is stable while the
-- request is pending, so the mux is purely combinational.
library ieee;
use ieee.std_logic_1164.all;

entity pcie_sb_decoder is
    port (
        sb_addr   : in  std_logic_vector(21 downto 0);
        sb_req    : in  std_logic;
        sb_ack    : out std_logic;
        sb_rdata  : out std_logic_vector(31 downto 0);
        sb_err    : out std_logic;

        wb_req    : out std_logic;
        wb_ack    : in  std_logic;
        wb_rdata  : in  std_logic_vector(31 downto 0);
        wb_err    : in  std_logic;

        dma_req   : out std_logic;
        dma_ack   : in  std_logic;
        dma_rdata : in  std_logic_vector(31 downto 0);

        ctl_req   : out std_logic;
        ctl_ack   : in  std_logic;
        ctl_rdata : in  std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of pcie_sb_decoder is
    signal region : std_logic_vector(1 downto 0);
begin
    region  <= sb_addr(21 downto 20);
    wb_req  <= sb_req when region = "00" else '0';
    dma_req <= sb_req when region = "01" else '0';
    ctl_req <= sb_req when region = "10" else '0';

    sb_ack   <= wb_ack    when region = "00" else
                dma_ack   when region = "01" else
                ctl_ack   when region = "10" else
                sb_req;                          -- unmapped: immediate error
    sb_rdata <= wb_rdata  when region = "00" else
                dma_rdata when region = "01" else
                ctl_rdata when region = "10" else
                x"BADADD00";
    sb_err   <= wb_err    when region = "00" else
                '0'       when region = "01" else
                '0'       when region = "10" else
                '1';
end architecture;
