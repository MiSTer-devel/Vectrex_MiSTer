---------------------------------------------------------------------------------
-- Vectrex cartridge interface
-- Copyright (C) 2026 Videodr0me
-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------------
-- Standard cartridges occupy 0000-7FFF; PB6 selects the half of a 64K image.
-- The SST39SF020A mapper occupies 0000-BFFF in each of four 48K banks selected
-- by IRQ and PB6.
-- Cartridge state survives machine reset and is replaced by the next download.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vectrex_cartridge is
port
(
	clock         : in  std_logic;

	download      : in  std_logic;
	download_wr   : in  std_logic;
	download_addr : in  std_logic_vector(24 downto 0);
	download_data : in  std_logic_vector(7 downto 0);

	backup_addr   : in  std_logic_vector(17 downto 0) := (others => '0');
	backup_data   : in  std_logic_vector(7 downto 0) := (others => '0');
	backup_wr     : in  std_logic := '0';
	backup_q      : out std_logic_vector(7 downto 0);
	flash_enabled : out std_logic;
	flash_busy    : out std_logic;
	flash_changed : out std_logic := '0';
	flash_sector  : out std_logic_vector(5 downto 0) := (others => '0');

	cpu_strobe   : in  std_logic;
	cpu_addr     : in  std_logic_vector(15 downto 0);
	cpu_data_out : in  std_logic_vector(7 downto 0);
	cpu_rw       : in  std_logic;
	cpu_selected : out std_logic;
	cpu_data_in  : out std_logic_vector(7 downto 0);

	pb6_out : in  std_logic;
	pb6_oe  : in  std_logic;
	pb6_in  : out std_logic;
	irq_n   : in  std_logic
);
end vectrex_cartridge;

architecture rtl of vectrex_cartridge is

	type cart_mode_t is (CART_STANDARD, CART_4X48);
	type flash_state_t is
	(
		FLASH_READ,
		FLASH_UNLOCK_1,
		FLASH_UNLOCK_2,
		FLASH_PROGRAM,
		FLASH_ERASE_1,
		FLASH_ERASE_2,
		FLASH_ERASE_3,
		FLASH_ID
	);
	type program_state_t is (PROGRAM_IDLE, PROGRAM_CAPTURE, PROGRAM_WRITE);

	constant CART_BYTES     : natural := 4 * 48 * 1024;
	constant FLASH_UNLOCK_A : std_logic_vector(15 downto 0) := X"5555";
	constant FLASH_UNLOCK_B : std_logic_vector(15 downto 0) := X"2AAA";

	type cart_memory_t is array(0 to CART_BYTES - 1) of std_logic_vector(7 downto 0);
	signal cart_memory : cart_memory_t;
	attribute ramstyle : string;
	attribute ramstyle of cart_memory : signal is "M10K, no_rw_check";

	signal cart_mode       : cart_mode_t := CART_STANDARD;
	signal download_q      : std_logic := '0';
	signal cart_present_q  : std_logic := '0';
	signal raw_4x48_seen   : std_logic := '0';
	signal addr_mask       : std_logic_vector(15 downto 0) := (others => '0');
	signal download_store  : std_logic;
	signal download_mapped : unsigned(17 downto 0);

	signal pb6_level     : std_logic;
	signal bank_4x48     : std_logic_vector(1 downto 0);
	signal standard_addr : std_logic_vector(15 downto 0);
	signal cpu_mapped    : unsigned(17 downto 0);
	signal cart_select   : std_logic;
	signal cpu_read      : std_logic;
	signal cpu_write     : std_logic;
	signal cpu_data_q    : std_logic_vector(7 downto 0) := (others => '0');

	signal flash_state   : flash_state_t := FLASH_READ;
	signal program_state : program_state_t := PROGRAM_IDLE;
	signal program_addr  : unsigned(17 downto 0) := (others => '0');
	signal program_data  : std_logic_vector(7 downto 0) := (others => '0');
	signal program_old   : std_logic_vector(7 downto 0) := (others => '0');
	signal erase_active  : std_logic := '0';
	signal erase_base    : unsigned(17 downto 0) := (others => '0');
	signal erase_count   : unsigned(11 downto 0) := (others => '0');
	signal erase_toggle  : std_logic := '0';
	signal memory_addr   : unsigned(17 downto 0);
	signal memory_data   : std_logic_vector(7 downto 0);
	signal memory_wr     : std_logic;

	function mapped_addr
	(
		bank : std_logic_vector(1 downto 0);
		addr : std_logic_vector(15 downto 0)
	) return unsigned is
		variable base : unsigned(17 downto 0);
	begin
		case bank is
			when "00"   => base := to_unsigned(16#00000#, 18);
			when "01"   => base := to_unsigned(16#0C000#, 18);
			when "10"   => base := to_unsigned(16#18000#, 18);
			when others => base := to_unsigned(16#24000#, 18);
		end case;
		return base + resize(unsigned(addr), 18);
	end function;

begin
	flash_enabled <= '1' when cart_mode = CART_4X48 else '0';
	flash_busy    <= '1' when erase_active = '1' or program_state /= PROGRAM_IDLE else '0';

	-- Port A serves CPU reads. Port B handles cartridge loading and flash
	-- updates, and reads or restores persistent flash data for save files.
	memory_addr <= download_mapped when download = '1' and download_store = '1' else
	               (others => '0') when download = '1' else
	               erase_base + erase_count when erase_active = '1' else
	               program_addr when program_state = PROGRAM_WRITE else
	               unsigned(backup_addr);
	memory_data <= download_data when download = '1' else
	               X"FF" when erase_active = '1' else
	               program_old and program_data when program_state = PROGRAM_WRITE else
	               backup_data;
	memory_wr   <= download_wr and download_store when download = '1' else
	               '1' when erase_active = '1' or program_state = PROGRAM_WRITE else
	               backup_wr;
	process(clock)
	begin
		if rising_edge(clock) then
			cpu_data_q <= cart_memory(to_integer(cpu_mapped));
			backup_q   <= cart_memory(to_integer(memory_addr));
			if memory_wr = '1' then
				cart_memory(to_integer(memory_addr)) <= memory_data;
			end if;
		end if;
	end process;

	-- A standard 64K cartridge and every 4x48K cartridge pull PB6 high.
	pb6_level <= pb6_out when pb6_oe = '1' else
	             '1'     when cart_mode = CART_4X48 else
	             addr_mask(15);
	pb6_in    <= pb6_level;
	bank_4x48 <= irq_n & pb6_level;

	cart_select <= '1' when cart_present_q = '1' and cart_mode = CART_4X48 and cpu_addr(15 downto 14) /= "11" else
	               '1' when cart_present_q = '1' and cart_mode = CART_STANDARD and cpu_addr(15) = '0' else
	               '0';
	cpu_selected <= cart_select;
	cpu_read     <= cpu_strobe and cpu_rw and cart_select;
	cpu_write    <= cpu_strobe and not cpu_rw and cart_select;

	standard_addr <= (pb6_level & cpu_addr(14 downto 0)) and addr_mask;
	cpu_mapped    <= mapped_addr(bank_4x48, cpu_addr) when cart_mode = CART_4X48 and cart_select = '1' else
	                 resize(unsigned(standard_addr), cpu_mapped'length) when cart_mode = CART_STANDARD else
	                 (others => '0');

	cpu_data_in <= X"BF" when cart_mode = CART_4X48 and flash_state = FLASH_ID and cpu_addr(0) = '0' else
	               X"B6" when cart_mode = CART_4X48 and flash_state = FLASH_ID else
	               '0' & erase_toggle & cpu_data_q(5 downto 0) when erase_active = '1' else
	               cpu_data_q;

	-- A 256 KiB flash image has four 64 KiB banks, each with 48 KiB visible to the CPU.
	-- Store those 48 KiB regions consecutively in the 192 KiB FPGA RAM.
	download_store <= '1' when download_addr(24 downto 18) = "0000000" and
	                           (download_addr(17 downto 16) = "00" or
	                            unsigned(download_addr(15 downto 0)) < 16#C000#) else
	                  '0';
	download_mapped <= mapped_addr(download_addr(17 downto 16), download_addr(15 downto 0));

	process(clock)
	begin
		if rising_edge(clock) then
			download_q    <= download;
			flash_changed <= '0';
			if download = '0' then
				if program_state = PROGRAM_WRITE and (program_old and program_data) /= program_old then
					flash_changed <= '1';
					flash_sector  <= std_logic_vector(program_addr(17 downto 12));
				elsif erase_active = '1' and erase_count = 4095 then
					flash_changed <= '1';
					flash_sector  <= std_logic_vector(erase_base(17 downto 12));
				end if;
			end if;

			case program_state is
				when PROGRAM_CAPTURE =>
					program_old   <= cpu_data_q;
					program_state <= PROGRAM_WRITE;

				when PROGRAM_WRITE =>
					program_state <= PROGRAM_IDLE;

				when others => null;
			end case;

			if download_q = '0' and download = '1' then
				cart_present_q <= download_wr and download_store;
				raw_4x48_seen  <= '0';
				addr_mask      <= (others => '0');
				cart_mode      <= CART_STANDARD;
				flash_state    <= FLASH_READ;
				program_state  <= PROGRAM_IDLE;
				erase_active   <= '0';
				erase_toggle   <= '0';
			else
				if download = '1' and download_wr = '1' then
					if download_store = '1' then
						cart_present_q <= '1';
					end if;
					if download_addr(24 downto 18) = "0000000" and
					   download_addr(17 downto 16) = "11" then
						raw_4x48_seen <= '1';
					end if;
					if (download_addr(15 downto 0) and not addr_mask) /= X"0000" then
						addr_mask <= addr_mask(14 downto 0) & '1';
					end if;
				end if;

				if download_q = '1' and download = '0' then
					if raw_4x48_seen = '1' then
						cart_mode <= CART_4X48;
					else
						cart_mode <= CART_STANDARD;
					end if;
				end if;

				if download = '0' and erase_active = '1' then
					if erase_count = 4095 then
						erase_active <= '0';
						erase_count  <= (others => '0');
					else
						erase_count <= erase_count + 1;
					end if;
				end if;

				if erase_active = '1' and cpu_read = '1' then
					erase_toggle <= not erase_toggle;
				end if;

				if download = '0' and cart_mode = CART_4X48 and cpu_write = '1' and
				   erase_active = '0' and
				   program_state = PROGRAM_IDLE then
					if cpu_data_out = X"F0" and flash_state /= FLASH_PROGRAM then
						flash_state <= FLASH_READ;
					else
						case flash_state is
							when FLASH_READ =>
								if cpu_addr = FLASH_UNLOCK_A and cpu_data_out = X"AA" then
									flash_state <= FLASH_UNLOCK_1;
								end if;

							when FLASH_UNLOCK_1 =>
								if cpu_addr = FLASH_UNLOCK_B and cpu_data_out = X"55" then
									flash_state <= FLASH_UNLOCK_2;
								else
									flash_state <= FLASH_READ;
								end if;

							when FLASH_UNLOCK_2 =>
								if cpu_addr = FLASH_UNLOCK_A and cpu_data_out = X"90" then
									flash_state <= FLASH_ID;
								elsif cpu_addr = FLASH_UNLOCK_A and cpu_data_out = X"A0" then
									flash_state <= FLASH_PROGRAM;
								elsif cpu_addr = FLASH_UNLOCK_A and cpu_data_out = X"80" then
									flash_state <= FLASH_ERASE_1;
								else
									flash_state <= FLASH_READ;
								end if;

							when FLASH_PROGRAM =>
								program_addr  <= cpu_mapped;
								program_data  <= cpu_data_out;
								program_state <= PROGRAM_CAPTURE;
								flash_state   <= FLASH_READ;

							when FLASH_ERASE_1 =>
								if cpu_addr = FLASH_UNLOCK_A and cpu_data_out = X"AA" then
									flash_state <= FLASH_ERASE_2;
								else
									flash_state <= FLASH_READ;
								end if;

							when FLASH_ERASE_2 =>
								if cpu_addr = FLASH_UNLOCK_B and cpu_data_out = X"55" then
									flash_state <= FLASH_ERASE_3;
								else
									flash_state <= FLASH_READ;
								end if;

							when FLASH_ERASE_3 =>
								if cpu_data_out = X"30" then
									erase_base   <= cpu_mapped(cpu_mapped'high downto 12) & X"000";
									erase_count  <= (others => '0');
									erase_active <= '1';
									erase_toggle <= '0';
								end if;
								flash_state <= FLASH_READ;

							when FLASH_ID => null;
						end case;
					end if;
				end if;
			end if;
		end if;
	end process;

end rtl;
