---------------------------------------------------------------------------------
-- Vectrex by Dar (darfpga@aol.fr) (27/12/2017)
-- http://darfpga.blogspot.fr
---------------------------------------------------------------------------------
-- Educational use only
-- Do not redistribute synthetized file with roms
-- Do not redistribute roms whatever the form
-- Use at your own risk
---------------------------------------------------------------------------------
--
-- Vectrex releases
--
-- Release 0.2 - 12/06/2018 - Dar
--	delays ramp related signals w.r.t. blank signal 
--	result is not perfect but clean sweep maze is much more correct and playable
--
-- Release 0.1 - 05/05/2018 - Dar
--		add sp0256-al2 VHDL speech simulation
--
-- Release 0.0 - 10/02/2018 - Dar
--		initial release
--
---------------------------------------------------------------------------------
-- SP0256-al2 prom decoding scheme and speech synthesis algorithm are from :
--
-- Copyright Joseph Zbiciak, all rights reserved.
-- Copyright tim lindner, all rights reserved.
--
-- See C source code and license in sp0256.c from MAME source
--
-- VHDL code is by Dar.
---------------------------------------------------------------------------------
-- gen_ram.vhd & io_ps2_keyboard
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
---------------------------------------------------------------------------------
-- VIA m6522
-- Copyright (c) MikeJ - March 2003
-- + modification
---------------------------------------------------------------------------------
-- YM2149 (AY-3-8910)
-- Copyright (c) MikeJ - Jan 2005
---------------------------------------------------------------------------------
-- cpu09l_128
-- Copyright (C) 2003 - 2010 John Kent
-- + modification
---------------------------------------------------------------------------------
-- Use vectrex_de10_lite.sdc to compile (Timequest constraints)
-- /!\
-- Don't forget to set device configuration mode with memory initialization
--  (Assignments/Device/Pin options/Configuration mode)
---------------------------------------------------------------------------------
-- Vectrex beam control hardware
--   Uses via port_A, dac and capacitor to set beam x/y displacement speed
--   when done beam displacement is released (port_B_7 = 0)
--   beam displacement duration is controled by Timer 1 (that drive port_B_7)
--   or by 6809 instructions execution duration.
--
--   Uses via port_A, dac and capacitor to set beam intensity before displacment

--   Before drawing any object (or text) the beam position is reset to screen center.
--   via_CA2 is used to reset beam position.
--
--	  Uses via_CB2 to set pen ON/OFF. CB2 is always driven by via shift register (SR)
--   output. SR is loaded with 0xFF for plain line drawing. SR is loaded with 0x00
--   for displacement with no drawing. SR is loaded with characters graphics
--   (character by character and line by line). SR is ALWAYS used in one shot mode
--   although SR bits are recirculated, SR shift stops on the last data bit (and
--   not on the first bit of data recirculated)
--
--   Exec_rom uses line drawing with Timer 1 and FF/00 SR loading (FF or 00 with
--   recirculation always output respectively 1 or 0). Timer 1 timeout is checked
--   by software polling loop.
--
--	  Exec_rom draw characters in the following manner : start displacement and feed
--   SR with character grahics (at the right time) till the end of the complete line.
--   Then move down one line and then backward up to the begining of the next line
--   with no drawing. Then start drawing the second line... ans so on 7 times.
--   CPU has enough time to get the next character and the corresponding graphics
--   line data between each SR feed. T1 is not used.
--
--   Most games seems to use those exec_rom routines.
--
--   During cut scene of spike sound sample have to be interlaced (through dac) while
--   drawing. Spike uses it's own routine for that job. That routine prepare drawing
--   data (graphics and vx/vy speeds) within working ram before cut scene start to be
--   able to feed sound sample between each movement segment. T1 and SR are used but
--   T1 timeout is not check. CPU expect there is enough time from T1 start to next
--   dac modification (dac ouput is alway vx during move). Modifying dac before T1
--   timeout will corrupt drawing. eg : when starting from @1230 (clr T1h), T1 must
--   have finished before reaching @11A4 (put sound sample value on dac). Drawing
--   characters with this routine is done by going backward between each character
--   graphic. Beam position is reset to screen center after/before each graphic line.
--   one sound sample is sent to dac after each character graphic.

---------------------------------------------------------------------------------
-- Video raster
--
--   requires 3 access per cycle =>
--   | read video scan buffer| Write video scan buffer | write vector beam |
--   => 75Mhz ram access with single ram (13ns access time)
--
--   implemented here as 4 separated buffers for 4 consecutives pixels
--   4 phases acces at 24MHz(25MHz)
--
--	  1) Read 1 pixel from each 4 buffers at video address => 4 pixels to be displayed
--   2) Write one pixel at beam vector address (ie to one buffer only)
--	  3) Write 1 pixel to each 4 buffers at video address => 4 pixels updated
--   4) Write one pixel at beam vector address (ie to one buffer only)
--
--   thus video refresh (VGA) is ok : 4 pixels every 4 clock periods (25MHz)
--   vector beam is continuously written at 12MHz (seems to be ok)
--
---------------------------------------------------------------------------------
--
-- Rasterizer enhancements and color mode by Sorgelig.
--
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.ALL;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity vectrex is
port
(
	clock		    : in  std_logic;
	reset        : in  std_logic;
	cpu          : in  std_logic;

	cart_data    : in  std_logic_vector(7 downto 0);
	cart_addr    : in  std_logic_vector(14 downto 0);
	cart_mask    : in  std_logic_vector(14 downto 0);
	cart_wr      : in  std_logic;

	video_r      : out std_logic_vector(7 downto 0);
	video_g      : out std_logic_vector(7 downto 0);
	video_b      : out std_logic_vector(7 downto 0);

	frame_line   : out std_logic;
	pers         : in  std_logic_vector(4 downto 0);
	color        : in  std_logic_vector(1 downto 0);
	overburn     : in  std_logic;

	video_width  : in  std_logic_vector(9 downto 0);
	video_height : in  std_logic_vector(9 downto 0);

	video_hblank : out std_logic;
	video_vblank : out std_logic;

	speech_mode  : in  std_logic;
	audio_out    : out signed(9 downto 0);

	up_1         : in  std_logic;
	dn_1         : in  std_logic;
	lf_1         : in  std_logic;
	rt_1         : in  std_logic;
	pot_x_1      : in  signed(7 downto 0);
	pot_y_1      : in  signed(7 downto 0);

	up_2         : in  std_logic;
	dn_2         : in  std_logic;
	lf_2         : in  std_logic;
	rt_2         : in  std_logic;
	pot_x_2      : in  signed(7 downto 0);
	pot_y_2      : in  signed(7 downto 0)
);
end vectrex;

architecture syn of vectrex is

--------------------------------------------------------------
-- Configuration
--------------------------------------------------------------
constant vram_width    : integer := 8;
constant max_h         : integer := 540; -- have to be multiple of 4
constant max_v         : integer := 720;
constant base_res      : integer := 5625;

constant max_x         : integer := base_res*4*8;
constant max_y         : integer := base_res*3*8;
--------------------------------------------------------------

signal clken_12        : std_logic;
signal clock_div2      : std_logic_vector(6 downto 0);
signal ce_250k         : std_logic;
signal cpu_en          : std_logic;
signal rQ              : std_logic;
signal E               : std_logic;

signal cpu_addr        : std_logic_vector(15 downto 0);
signal cpu_di          : std_logic_vector( 7 downto 0);
signal cpu_do          : std_logic_vector( 7 downto 0);
signal cpu_rw          : std_logic;

signal ram_cs          : std_logic;
signal ram_do          : std_logic_vector( 7 downto 0);
signal ram_we          : std_logic;

signal rom_cs          : std_logic;
signal rom_do          : std_logic_vector( 7 downto 0);

signal cart_cs         : std_logic;
signal cart_do         : std_logic_vector( 7 downto 0);

signal via_cs_n        : std_logic;
signal via_do          : std_logic_vector(7 downto 0);
signal via_ca2_o       : std_logic;
signal via_cb2_o       : std_logic;
signal via_pa_o        : std_logic_vector(7 downto 0);
signal via_pb_o        : std_logic_vector(7 downto 0);
signal via_irq_n       : std_logic;

type delay_buffer_t is array(0 to 255) of std_logic_vector(17 downto 0);
signal delay_buffer    : delay_buffer_t;

signal via_ca2_o_d     : std_logic;
signal via_cb2_o_d     : std_logic;
signal via_pa_o_d      : std_logic_vector(7 downto 0);
signal via_pb_o_d      : std_logic_vector(7 downto 0);

signal sh_dac          : std_logic;
signal dac_mux         : std_logic_vector(2 downto 1);
signal zero_integrator_n : std_logic;
signal ramp_integrator_n : std_logic;
signal beam_blank_n      : std_logic;

signal dac             : signed(8 downto 0);
signal dac_y           : signed(8 downto 0);
signal dac_z           : std_logic_vector(7 downto 0);
signal ref_level       : signed(8 downto 0);
signal dac_sound       : std_logic_vector(7 downto 0);

signal integrator_x    : signed(19 downto 0);
signal integrator_y    : signed(19 downto 0);

signal shifted_x       : signed(19 downto 0);
signal shifted_y       : signed(19 downto 0);

signal limited_x       : integer;
signal limited_y       : integer;

signal beam_h          : unsigned(9 downto 0);
signal beam_v          : unsigned(9 downto 0);

signal beam_hd         : unsigned(9 downto 0);
signal beam_vd         : unsigned(9 downto 0);
signal beam_cnt        : integer;

signal beam_blank_buffer    : std_logic_vector(5 downto 0);
signal beam_blank_n_delayed : std_logic;

signal beam_video_addr : std_logic_vector(19 downto 0);
signal scan_video_addr : std_logic_vector(19 downto 0);
signal video_addr      : std_logic_vector(17 downto 0);

signal phase           : std_logic_vector(1 downto 0);

signal video_we_0      : std_logic;
signal video_we_1      : std_logic;
signal video_we_2      : std_logic;
signal video_we_3      : std_logic;
signal video_rd        : std_logic;
signal video_pixel     : std_logic_vector(7 downto 0);

signal read_0          : std_logic_vector(vram_width-1 downto 0);
signal read_0b         : std_logic_vector(vram_width-1 downto 0);
signal read_1          : std_logic_vector(vram_width-1 downto 0);
signal read_1b         : std_logic_vector(vram_width-1 downto 0);
signal read_2          : std_logic_vector(vram_width-1 downto 0);
signal read_2b         : std_logic_vector(vram_width-1 downto 0);
signal read_3          : std_logic_vector(vram_width-1 downto 0);
signal read_3b         : std_logic_vector(vram_width-1 downto 0);
signal pixel           : std_logic_vector(vram_width-1 downto 0);

signal write_0         : std_logic_vector(vram_width-1 downto 0);
signal write_1         : std_logic_vector(vram_width-1 downto 0);
signal write_2         : std_logic_vector(vram_width-1 downto 0);
signal write_3         : std_logic_vector(vram_width-1 downto 0);

signal hcnt            : std_logic_vector(9 downto 0);
signal vcnt            : std_logic_vector(9 downto 0);

signal hblank          : std_logic;
signal vblank          : std_logic;

signal ay_do           : std_logic_vector(7 downto 0);
signal ay_chan_a       : std_logic_vector(7 downto 0);
signal ay_chan_b       : std_logic_vector(7 downto 0);
signal ay_chan_c       : std_logic_vector(7 downto 0);
signal ay_ioa_oe       : std_logic;


signal pot             : signed(7 downto 0);
signal compare         : std_logic;
signal players_switches: std_logic_vector(7 downto 0);

signal vectrex_bd_rate_div       : std_logic_vector(7 downto 0) := X"00";
signal vectrex_serial_bit_in     : std_logic;
signal vectrex_serial_bit_in_d   : std_logic;
signal vectrex_serial_data_shift : std_logic_vector(7 downto 0) := X"00";
signal vectrex_serial_bit_cnt    : std_logic_vector(3 downto 0) := X"0";
signal vectrex_serial_byte_rdy   : std_logic;
signal vectrex_serial_byte_out   : std_logic_vector(7 downto 0) := X"00";

signal audio_ay       : std_logic_vector(11 downto 0);
signal audio_speech   : signed(9 downto 0);
signal speech_rdy     : std_logic;
signal sp0256_rdy     : std_logic;

signal pix_g,pix_r,pix_b : std_logic;
signal subt            : std_logic_vector(7 downto 0);
signal mask            : std_logic_vector(7 downto 0);
signal pix             : std_logic_vector(7 downto 0);
signal pix_fx          : std_logic_vector(7 downto 0);
signal pix_c           : std_logic_vector(7 downto 0);
signal pix_cc          : std_logic_vector(7 downto 0);
signal dac_ob          : std_logic_vector(7 downto 0);

component mc6809 is port
(
	CPU    : in  std_logic;

	CLK    : in  std_logic;
	CLKEN  : in  std_logic;

	E      : out std_logic;
	riseE  : out std_logic;
	fallE  : out std_logic;

	Q      : out std_logic;
	riseQ  : out std_logic;
	fallQ  : out std_logic;

	Din    : in  std_logic_vector(7 downto 0);
	Dout   : out std_logic_vector(7 downto 0);
	ADDR   : out std_logic_vector(15 downto 0);
	RnW    : out std_logic;

	nIRQ   : in  std_logic := '1';
	nFIRQ  : in  std_logic := '1';
	nNMI   : in  std_logic := '1';
	nHALT  : in  std_logic := '1';
	nRESET : in  std_logic := '1'
);
end component mc6809;

component ym2149
port (
	CLK       : in  std_logic;
	CE        : in  std_logic;
	RESET     : in  std_logic;
	BDIR      : in  std_logic;
	BC        : in  std_logic;
	DI        : in  std_logic_vector(7 downto 0);
	DO        : out std_logic_vector(7 downto 0);
	CHANNEL_A : out std_logic_vector(7 downto 0);
	CHANNEL_B : out std_logic_vector(7 downto 0);
	CHANNEL_C : out std_logic_vector(7 downto 0);

	SEL       : in  std_logic;
	MODE      : in  std_logic;

	IOA_in    : in  std_logic_vector(7 downto 0);
	IOA_out   : out std_logic_vector(7 downto 0);
	IOA_OEn   : out std_logic;

	IOB_in    : in  std_logic_vector(7 downto 0);
	IOB_out   : out std_logic_vector(7 downto 0);
	IOB_OEn   : out std_logic
);
end component;

begin

--static ADDRESS_MAP_START(vectrex_map, AS_PROGRAM, 8, vectrex_state )
--	AM_RANGE(0x0000, 0x7fff) AM_NOP // cart area, handled at machine_start
--	AM_RANGE(0xc800, 0xcbff) AM_RAM AM_MIRROR(0x0400) AM_SHARE("gce_vectorram")
--	AM_RANGE(0xd000, 0xd7ff) AM_READWRITE(vectrex_via_r, vectrex_via_w)
--	AM_RANGE(0xe000, 0xffff) AM_ROM AM_REGION("maincpu", 0)
--ADDRESS_MAP_END

-- beam control


-- integrator related signals have to be delayed with respect to blank signal
-- tuned value : ~94 @ clock_12
-- (port A, port B, CA2 and CB2 are declared to be delayed. Unsued delayed signals/buffers
-- will be removed automaticaly by compiler so no ressources will be wasted)

process (clock)
begin
	if rising_edge(clock) then
		if clken_12 = '1' then
			delay_buffer(0) <= via_cb2_o & via_ca2_o & via_pb_o & via_pa_o;
			for i in 255 downto 1 loop
				delay_buffer(i) <= delay_buffer(i-1) ;
			end loop;

			via_pa_o_d  <= delay_buffer(94)( 7 downto 0);
			via_pb_o_d  <= delay_buffer(94)(15 downto 8);
			via_ca2_o_d <= delay_buffer(94)(16);
			--via_cb2_o_d <= delay_buffer(94)(17);
		end if;
	end if;
end process;

sh_dac            <= via_pb_o_d(0);
dac_mux           <= via_pb_o_d(2 downto 1);
zero_integrator_n <= via_ca2_o_d;
ramp_integrator_n <= via_pb_o_d(7);
beam_blank_n      <= via_cb2_o;      -- blank is not delayed

dac <= signed(via_pa_o_d(7)&via_pa_o_d); -- must ensure sign extension for 0x80 value to be used in integrator equation

process (clock)
	variable limit_n : std_logic;
begin
	if rising_edge(clock) then
		if clken_12 = '1' then

			if sh_dac = '0' then
				case dac_mux is
				when "00"   => dac_y     <= dac;
				when "01"   => ref_level <= dac;
				when "10"   => dac_z     <= via_pa_o_d;
				when others => dac_sound <= via_pa_o_d;
				end case;
			end if;

			if zero_integrator_n = '0' then
				integrator_x <= (others=>'0');
				integrator_y <= (others=>'0');
			else
				if ramp_integrator_n = '0' then
					integrator_x <= integrator_x + (ref_level - dac_y);
					integrator_y <= integrator_y - (ref_level - dac);
				end if;
			end if;

			-- set 'preserve registers' wihtin assignments editor to ease signaltap debuging

			shifted_x <= integrator_x+max_x;
			shifted_y <= integrator_y+max_y;

			-- limit and scaling should be enhanced

			limit_n := '1';
			if    shifted_x > 2*max_x then limited_x <= 2*max_x; limit_n := '0';
			elsif shifted_x < 0       then limited_x <= 0;       limit_n := '0';
			else                           limited_x <= to_integer(unsigned(shifted_x)); end if;

			if    shifted_y > 2*max_y then limited_y <= 2*max_y; limit_n := '0';
			elsif shifted_y < 0       then limited_y <= 0; 		  limit_n := '0';
			else                           limited_y <= to_integer(unsigned(shifted_y)); end if;

			-- integer computation to try making rounding computation during division

			beam_v <= to_unsigned((limited_x*to_integer(unsigned(video_height)))/(2*max_x),10);
			beam_h <= to_unsigned((limited_y*to_integer(unsigned(video_width)))/(2*max_y),10);

			beam_video_addr <= std_logic_vector(beam_v * unsigned(video_width) + beam_h);

			-- compense beam_video_addr computation delay vs beam_blank

			beam_blank_buffer <= beam_blank_buffer(4 downto 0) & beam_blank_n;

			beam_blank_n_delayed <= beam_blank_buffer(3) and limit_n;

			beam_hd <= beam_h;
			beam_vd <= beam_v;

			if(beam_blank_n_delayed = '1' and beam_v = beam_vd and beam_h = beam_hd) then
				if(dac_ob < 255) then
					dac_ob <= dac_ob + 5;
				end if;
			else
				dac_ob <= (others => '0');
			end if;

		end if;
	end if;
end process;

-- video buffer
--
-- 4 phases : (beam is fully asynchrone with video scanner)
--
-- |read previous pixels| write beam pixel | write updated pixels | write beam pixel |
-- |from the 4 buffers  | to one buffer    | to the 4 buffers     | to one buffer    |
--
process (clock)
begin
	if rising_edge(clock) then
		phase <= hcnt(1 downto 0);

		video_we_0 <= '0';
		video_we_1 <= '0';
		video_we_2 <= '0';
		video_we_3 <= '0';
		clken_12   <= '0';
		cpu_en     <= '0';

		case phase is
			when "00" =>
				cpu_en <= '1';
				video_addr <= scan_video_addr(19 downto 2);

			when "10" =>
				video_addr <= scan_video_addr(19 downto 2);
				if hblank = '0' and vblank = '0' then
					if read_0 > X"00" then video_we_0 <= '1'; if((read_0 and mask) > subt) then write_0 <= read_0 - subt; else write_0 <= (others => '0'); end if; end if;
					if read_1 > X"00" then video_we_1 <= '1'; if((read_1 and mask) > subt) then write_1 <= read_1 - subt; else write_1 <= (others => '0'); end if; end if;
					if read_2 > X"00" then video_we_2 <= '1'; if((read_2 and mask) > subt) then write_2 <= read_2 - subt; else write_2 <= (others => '0'); end if; end if;
					if read_3 > X"00" then video_we_3 <= '1'; if((read_3 and mask) > subt) then write_3 <= read_3 - subt; else write_3 <= (others => '0'); end if; end if;
				end if;

			when others =>
				clken_12 <= '1';
				video_addr <= beam_video_addr(19 downto 2);
				if beam_blank_n_delayed = '1' then
					case beam_video_addr(1 downto 0) is

						when "00"   => video_we_0 <= '1'; write_0 <= pix;
						when "01"   => video_we_1 <= '1'; write_1 <= pix;
						when "10"   => video_we_2 <= '1'; write_2 <= pix;
						when others => video_we_3 <= '1'; write_3 <= pix;

					end case;
				end if;
		end case;

		if phase = "01" then
			read_0 <= read_0b;
			read_1 <= read_1b;
			read_2 <= read_2b;
			read_3 <= read_3b;
		end if;

		case phase is
			when "10"   => pixel <= read_0;
			when "11"   => pixel <= read_1;
			when "00"   => pixel <= read_2;
			when others => pixel <= read_3;
		end case;

	end if;
end process;

pix_fx<= dac_z(6 downto 0)&dac_z(6) when overburn = '0' else X"FF" when (to_integer(unsigned(dac_z))+to_integer(unsigned(dac_ob)))>255 else dac_z+dac_ob;

subt  <= pers&"000" when color = "00" else "000"&pers;
mask  <= "11111111" when color = "00" else "00011111";
pix   <= pix_fx     when color = "00" else (via_pa_o(7) or via_pa_o(6) or via_pa_o(5) or via_pa_o(4))&(via_pa_o(3) or via_pa_o(2))&(via_pa_o(1) or via_pa_o(0))&pix_fx(7 downto 3);

pix_g <= pixel(7) or not (pixel(6) or pixel(5));
pix_r <= pixel(6) or not (pixel(7) or pixel(5));
pix_b <= pixel(5) or not (pixel(7) or pixel(6));
pix_c <= pixel(4 downto 0)&pixel(4 downto 2);
pix_cc<= std_logic_vector(shift_right(unsigned(pix_c), to_integer(unsigned(color))));

video_r <= pixel when color = "00" else pix_c when pix_r = '1' else pix_cc;
video_g <= pixel when color = "00" else pix_c when pix_g = '1' else pix_cc;
video_b <= pixel when color = "00" else pix_c when pix_b = '1' else pix_cc;

buf_0 : entity work.gen_ram generic map( dWidth => vram_width, aWidth => 18, nWords => max_h*max_v/4)
port map( clk => not clock, we => video_we_0, addr => video_addr, d => write_0, q => read_0b);

buf_1 : entity work.gen_ram generic map( dWidth => vram_width, aWidth => 18, nWords => max_h*max_v/4)
port map( clk => not clock, we => video_we_1, addr => video_addr, d => write_1, q => read_1b);

buf_2 : entity work.gen_ram generic map( dWidth => vram_width, aWidth => 18, nWords => max_h*max_v/4)
port map( clk => not clock, we => video_we_2, addr => video_addr, d => write_2, q => read_2b);

buf_3 : entity work.gen_ram generic map( dWidth => vram_width, aWidth => 18, nWords => max_h*max_v/4)
port map( clk => not clock, we => video_we_3, addr => video_addr, d => write_3, q => read_3b);

-------------------
-- Video scanner --
-------------------
process (clock)
begin
	if rising_edge(clock) then

		hcnt <= hcnt + '1';
		if hcnt = 553 then
			hcnt <= (others => '0');
			if vcnt = 721 then
				vcnt <= (others => '0');
			else
				vcnt <= vcnt + '1';
			end if;
		end if;

		if vcnt = 0 or vcnt = (video_height-2) then
			if hcnt = 3             then frame_line <= '1'; end if;
			if hcnt = video_width+3 then frame_line <= '0'; end if;
		elsif vcnt > 0 and vcnt < (video_height-2) then
			if hcnt = 3 or hcnt = video_width+2 then
				frame_line <= '1';
			else
				frame_line <= '0';
			end if;
		else frame_line <= '0';	end if;

		if hcnt =             3 then hblank <= '0'; end if;
		if hcnt = video_width+3 then hblank <= '1'; end if;
		if vcnt =             0 then vblank <= '0'; end if;
		if vcnt = video_height  then vblank <= '1'; end if;

	end if;
end process;

video_hblank <= hblank;
video_vblank <= vblank;

scan_video_addr <= vcnt * video_width + hcnt;

--------------------------------------------------------------------

main_rom : entity work.bios_rom
port map
(
	clk  => clock,
	addr => cpu_addr(12 downto 0),
	data => rom_do
);

cart_rom : entity work.gen_rom
port map
(
	data	    => cart_data,
	wraddress => cart_addr,
	wrclock	 => clock,
	wren	    => cart_wr,

	rdclock   => clock,
	rdaddress => (cpu_addr(14 downto 0) and cart_mask),
	q         => cart_do
);

ram : entity work.gen_dpram
generic map(10, 8)
port map
(
	clock_a	 => clock,
	address_a => cart_addr(9 downto 0),
	data_a	 => (others => '0'),
	wren_a	 => cart_wr,

	clock_b	 => clock,
	wren_b	 => ram_we and rQ,
	address_b => cpu_addr(9 downto 0),
	data_b	 => cpu_do,
	q_b		 => ram_do
);

--------------------------------------------------------------------

-- chip select
cart_cs  <= '1' when cpu_addr(15) = '0' else '0';
ram_cs   <= '1' when cpu_addr(15 downto 12) = X"C"  else '0';
via_cs_n <= '0' when cpu_addr(15 downto 12) = X"D"  else '1';
rom_cs   <= '1' when cpu_addr(15 downto 13) = "111" else '0';

-- write enable working ram
ram_we <=   '1' when cpu_rw = '0' and ram_cs = '1' else '0';

cpu_di <= cart_do when cart_cs  = '1' else
			 ram_do  when ram_cs   = '1' else
			 via_do  when via_cs_n = '0' else
			 rom_do  when rom_cs   = '1' else
			 X"00";

-- players controls / + speech serial handshake in speech mode
players_switches <= not(rt_2&lf_2&dn_2&up_2&rt_1&lf_1&dn_1&up_1) when speech_mode = '0'
else                speech_rdy&speech_rdy&speech_rdy&speech_rdy & not(rt_1&lf_1&dn_1&up_1);

with via_pb_o(2 downto 1) select  -- dac_mux but not delayed
pot <= pot_x_1 when "00",
		 pot_y_1 when "01",
		 pot_x_2 when "10",
		 pot_y_2 when others;

compare <= '1' when (pot(7)&pot) > signed(via_pa_o(7)&via_pa_o) else '0'; -- dac but not delayed

--------------------------------------------------------------------

main_cpu : mc6809
port map
(
	CLK    => clock,
	CLKEN  => cpu_en,
	nRESET => not reset,
	CPU    => cpu,

	E      => E,
	riseQ  => rQ,

	Din    => cpu_di,
	Dout   => cpu_do,
	ADDR   => cpu_addr,
	RnW    => cpu_rw,

	nIRQ   => via_irq_n,
	nFIRQ  => not rt_1
);


via6522_inst : entity work.M6522
port map(
	I_RS    => cpu_addr(3 downto 0),
	I_DATA  => cpu_do,
	O_DATA  => via_do,

	I_RW_L  => cpu_rw,
	I_CS1   => cpu_addr(12),
	I_CS2_L => via_cs_n,

	O_IRQ_L => via_irq_n,

	-- port a
	I_CA1   => not rt_2,
	I_CA2   => '0',
	O_CA2   => via_ca2_o,

	I_PA    => ay_do,
	O_PA    => via_pa_o,

	-- port b
	I_CB1   => '0',
	O_CB1   => open,

	I_CB2   => '0',
	O_CB2   => via_cb2_o,

	I_PB    => "00"&compare&"00000",
	O_PB    => via_pb_o,

	RESET_L => not reset,
	CLK     => clock,
	I_P2_H  => not E, -- high for phase 2 clock  ____----__
	ENA_4   => cpu_en -- 4x system clock         _-_-_-_-_-
);

-- sound	

ay_3_8910 : ym2149
port map(
	DI        => via_pa_o,
	DO        => ay_do,
	BDIR      => via_pb_o(4),
	BC        => via_pb_o(3),

	SEL       => '0',
	MODE      => '0',

	CHANNEL_A => ay_chan_a,
	CHANNEL_B => ay_chan_b,
	CHANNEL_C => ay_chan_c,

	IOA_in    => players_switches,
	IOA_OEn   => ay_ioa_oe,

	IOB_in    => (others => '0'),

	CE        => rQ,
	RESET     => reset,
	CLK       => clock
);

audio_ay  <=  ("0000"&ay_chan_a) + ("0000"&ay_chan_b) + ("0000"&ay_chan_c) + ("0000"&dac_sound);
audio_out <=  signed(audio_ay(11 downto 2)) + audio_speech;

-- vectrex just toggle port A forced/high Z to produce serial data
-- when in high Z vectrex sense port A to get speech chip ready for new byte
vectrex_serial_bit_in <= ay_ioa_oe;

-- get serial data from vectrex joystick port
process (clock, reset)
  begin
	if reset='1' then
		vectrex_bd_rate_div <= X"00";
	else
      if rising_edge(clock) then
			if rQ = '1' then
				vectrex_serial_bit_in_d <= vectrex_serial_bit_in;

				if vectrex_serial_bit_in /= vectrex_serial_bit_in_d then -- reset baud counter on either edge
					vectrex_bd_rate_div <= X"00";
				else
					if vectrex_bd_rate_div = X"9B" then -- 1.5MHz/156 = 9615kHz
						vectrex_bd_rate_div <= X"00";
					else
						vectrex_bd_rate_div <= vectrex_bd_rate_div + '1';
					end if;
				end if;

				if vectrex_bd_rate_div = X"4E" then
					vectrex_serial_data_shift <=  vectrex_serial_bit_in  & vectrex_serial_data_shift(7 downto 1); -- serial is lsb first (ok speakjet/vecvoice/vecvox)

					if vectrex_serial_bit_cnt = X"0" and vectrex_serial_bit_in = '0' then
						vectrex_serial_bit_cnt <= X"1";
						vectrex_serial_byte_rdy <= '0';
					end if;

					if vectrex_serial_bit_cnt > X"0" then
						vectrex_serial_bit_cnt <= vectrex_serial_bit_cnt + '1';
					end if;

					if vectrex_serial_bit_cnt = X"A" then
						vectrex_serial_bit_cnt <= X"0";
					end if;

				end if;

				if vectrex_bd_rate_div = X"60" then
					if vectrex_serial_bit_cnt = X"9" then
						vectrex_serial_byte_rdy <= '1';
						vectrex_serial_byte_out <= vectrex_serial_data_shift;
					end if;
				end if;
			end if;
		end if;
	end if;
end process;

process (clock, reset)
begin
	if reset='1' then
		clock_div2 <= (others=>'0');
	else
		if rising_edge(clock) then
			ce_250k <= '0';
			if clock_div2 >= 95 then
				clock_div2 <= (others=>'0');
				ce_250k <= '1';
			else
				clock_div2 <= clock_div2 + '1';
			end if;
		end if;
	end if;
end process;

-- sp0256 VHDL simulation
speech_rdy <= not sp0256_rdy;

sp0256 : entity work.sp0256
port map
(
	clock          => clock,
	ce             => ce_250k,
	reset          => reset,

	input_rdy      => sp0256_rdy,
	allophone      => vectrex_serial_byte_out(5 downto 0),
	trig_allophone => vectrex_serial_byte_rdy,

	audio_out      => audio_speech
);

end SYN;
