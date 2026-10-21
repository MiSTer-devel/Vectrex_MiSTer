---------------------------------------------------------------------------------
-- Vectrex by Dar (darfpga@aol.fr) (27/12/2017)
-- http://darfpga.blogspot.fr
-- MiSTer adaptation by Sorgelig (15/04/2018)
-- Enhanced core rebuild by Videodr0me (07/10/2026)
---------------------------------------------------------------------------------
-- Educational use only
-- Do not redistribute synthetized file with roms
-- Do not redistribute roms whatever the form
-- Use at your own risk
---------------------------------------------------------------------------------
-- Original Dar release history
-- Release 0.0 - 10/02/2018 - Dar
--   Initial release.
-- Release 0.1 - 05/05/2018 - Dar
--   Added SP0256-AL2 VHDL speech simulation.
-- Release 0.2 - 12/06/2018 - Dar
--   Delayed RAMP relative to BLANK for vector alignment.
---------------------------------------------------------------------------------
-- MiSTer adaptation and updates - 15/04/2018 to 23/11/2023 - Sorgelig
--   Ported Dar's core to MiSTer with cartridge loading, digital/analog
--   controls, video/audio output and OSD integration.
--   Reworked rasterizer persistence, overburn and color modes.
--   Updated CPU/PSG integration, clocking and reset handling.
--   Added automatic overlay loading and corrected overlay rendering.
--   Added custom aspect ratios, integer scaling and display rotation.
---------------------------------------------------------------------------------
-- Overlay support - 08/07/2020 - Alan Steremberg (alanswx)
--   Added the original overlay loading, storage and blending implementation.
---------------------------------------------------------------------------------
-- Enhanced core rebuild - 07/10/2026 - Videodr0me
--   HD vector renderer: CRT halo, bloom and phosphor-decay effects,
--     stationary dwells, configurable brightness and
--     phosphor colors, and smooth highlight spill with linear-light processing.
--   Video output: 1080p, 720p, 480p, 480i and 240p, optional 720p at 120 Hz,
--     and 15 kHz/31 kHz CRT support through analog and Direct Video output.
--   CRT profiles: resolution-dependent presets and two independently saved
--     custom profiles, with editable rendering controls, keyboard profile
--     selection and copying of active settings into either custom profile.
--   HD overlays: multi-resolution ART packages for normal and both TATE
--     orientations, with automatic, manual and startup loading (boot2.rom).
--     Translucent filtering and linear-light blending with brightness
--     compensation, independent tint and artwork-brightness controls.
--   Geometry: normal, clockwise and counterclockwise orientation,
--     Overlay/Screen framing, Standard/Open Matte viewing, vertical-offset
--     compensation and selectable aspect-ratio behavior.
--     Remappable View control with matching menu settings and on-screen feedback.
--   Frame handling: game-aware redraw detection using Timer 2 activity,
--     adaptive fallback for irregular redraw patterns, and adaptive
--     framebuffer presentation and phosphor accumulation.
--   CPU/VIA accuracy: corrected CPU behavior, VIA timers and shift output,
--     interrupt handling, bus timing, address decoding and open-bus retention.
--   Analog beam model: calibrated RAMP and blanking timing, sample-and-hold
--     acquisition and beam-energy accumulation for lines and stationary dots.
--   Cartridge support: 64 KiB PB6 banking and 256 KiB SST39SF020A flash
--     cartridges, including Vector Patrol, Vectorblade and Telengard.
--     Flash programming and erase, persistent per-game saves, automatic
--     restore, autosave and manual saving.
--   Audio: replaced the YM2149 module with JT49, corrected signed DAC audio
--     and calibrated mixing against real hardware. Corrected VecVoice/SP0256
--     controller-port isolation, with adjustable speech volume.
--   Cold-start RAM initialization: timestamp-seeded random state,
--     with RAM retention across warm resets.
--   Pause: manual pause, optional pause while the OSD is open,
--     and automatic dimming of the paused display.
--   See ../CHANGELOG.md for core-wide changes.
---------------------------------------------------------------------------------
-- SP0256-AL2 PROM decoding scheme and speech synthesis algorithm:
-- Copyright Joseph Zbiciak, all rights reserved.
-- Copyright Tim Lindner, all rights reserved.
-- See C source code and license in sp0256.c from MAME source.
-- VHDL implementation by Dar.
---------------------------------------------------------------------------------
-- VIA 6522 by Gideon Zweijtzer with accuracy fixes by Videodr0me.
---------------------------------------------------------------------------------
-- AY-3-8912 emulation uses JT49 by Jose Tejada Gomez.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.all;

entity vectrex is
port
(
	clock        : in  std_logic;
	reset        : in  std_logic;
	pause        : in  std_logic;
	bios_factory : in  std_logic;
	boot_reset   : in  std_logic := '0';
	timestamp    : in  std_logic_vector(32 downto 0) := (others => '0');

	cart_download : in  std_logic;
	cart_data     : in  std_logic_vector(7 downto 0);
	cart_addr     : in  std_logic_vector(24 downto 0);
	cart_wr       : in  std_logic;
	backup_addr   : in  std_logic_vector(17 downto 0) := (others => '0');
	backup_data   : in  std_logic_vector(7 downto 0) := (others => '0');
	backup_wr     : in  std_logic := '0';
	backup_q      : out std_logic_vector(7 downto 0);
	flash_enabled : out std_logic;
	flash_busy    : out std_logic;
	flash_changed : out std_logic;
	flash_sector  : out std_logic_vector(5 downto 0);

	speech_mode  : in  std_logic;
	speech_level : in  std_logic_vector(1 downto 0);
	audio_out    : out signed(9 downto 0);

	up_1    : in  std_logic;
	dn_1    : in  std_logic;
	lf_1    : in  std_logic;
	rt_1    : in  std_logic;
	pot_x_1 : in  signed(7 downto 0);
	pot_y_1 : in  signed(7 downto 0);

	up_2    : in  std_logic;
	dn_2    : in  std_logic;
	lf_2    : in  std_logic;
	rt_2    : in  std_logic;
	pot_x_2 : in  signed(7 downto 0);
	pot_y_2 : in  signed(7 downto 0);

	-- Beam state consumed by the external renderer.
	beam_x      : out signed(19 downto 0);
	beam_y      : out signed(19 downto 0);
	beam_on     : out std_logic;
	beam_z      : out std_logic_vector(7 downto 0);
	beam_ce     : out std_logic;
	beam_zero_n : out std_logic;
	-- Accepted Timer 2 reload pulse and period in the machine clock domain.
	t2_reload : out std_logic;
	t2_period : out std_logic_vector(15 downto 0);
	-- PiTrex mode: the 6809 is held in reset and the ARM command player
	-- drives the bus (one access per E-cycle, from the falling-E enable).
	ptx_enable : in  std_logic := '0';
	ptx_addr   : in  std_logic_vector(15 downto 0) := (others => '1');
	ptx_do     : in  std_logic_vector( 7 downto 0) := (others => '0');
	ptx_rw     : in  std_logic := '1';
	e_fall_o   : out std_logic;
	psg_ioa_o  : out std_logic_vector(7 downto 0)
);
end vectrex;

architecture syn of vectrex is

--------------------------------------------------------------
-- Configuration
--------------------------------------------------------------
constant analog_delay_ticks  : natural := 94;
constant ramp_delay_clocks   : natural := 204;
constant ramp_release_clocks : natural := 24;
constant cb2_delay_clocks    : natural := 24;

--------------------------------------------------------------

signal clken_12            : std_logic;
signal speech_enable_count : unsigned(6 downto 0);
signal ce_250k             : std_logic;
signal cpu_en              : std_logic;
signal rQ                  : std_logic;
signal cpu_e_rise          : std_logic;
signal cpu_e_fall          : std_logic;

signal cpu_addr       : std_logic_vector(15 downto 0);
signal cpu_di         : std_logic_vector( 7 downto 0);
signal cpu_do         : std_logic_vector( 7 downto 0);
signal cpu_rw         : std_logic;
signal cpu_addr_core  : std_logic_vector(15 downto 0);
signal cpu_do_core    : std_logic_vector( 7 downto 0);
signal cpu_rw_core    : std_logic;
signal cpu_bus_hold_q : std_logic_vector( 7 downto 0) := (others => '0');

signal ram_cs        : std_logic;
signal ram_do        : std_logic_vector( 7 downto 0);
signal ram_cpu_write : std_logic;

signal rom_cs         : std_logic;
signal rom_do         : std_logic_vector( 7 downto 0);
signal rom_fixed_do   : std_logic_vector( 7 downto 0);
signal rom_factory_do : std_logic_vector( 7 downto 0);

signal cart_cs  : std_logic;
signal cart_do  : std_logic_vector( 7 downto 0);
signal cart_pb6 : std_logic;

signal via_cs           : std_logic;
signal via_do           : std_logic_vector(7 downto 0);
signal via_ca2_o        : std_logic;
signal via_cb2_o        : std_logic;
signal via_pa_o         : std_logic_vector(7 downto 0);
signal via_pb_o         : std_logic_vector(7 downto 0);
signal via_irq_n        : std_logic;
signal via_irq          : std_logic;
signal via_read         : std_logic;
signal via_write        : std_logic;
signal via_write_accept : std_logic;
signal t2_low_write     : std_logic;
signal t2_high_write    : std_logic;
signal via_pa_i         : std_logic_vector(7 downto 0);
signal via_pb_i         : std_logic_vector(7 downto 0);
signal via_pa_oe        : std_logic_vector(7 downto 0);
signal via_pb_oe        : std_logic_vector(7 downto 0);
signal via_ca2_i        : std_logic;
signal via_cb1_i        : std_logic;
signal via_cb2_i        : std_logic;
signal via_cb1_o        : std_logic;
signal via_ca2_oe       : std_logic;
signal via_cb1_oe       : std_logic;
signal via_cb2_oe       : std_logic;
signal t2_low_q         : std_logic_vector(7 downto 0);

type delay_buffer_t is array(0 to analog_delay_ticks) of std_logic_vector(11 downto 0);
signal delay_buffer    : delay_buffer_t;

signal via_pa_o_d        : std_logic_vector(7 downto 0);
signal sh_dac            : std_logic;
signal dac_mux           : std_logic_vector(1 downto 0);
signal zero_integrator_n : std_logic;
signal ramp_integrator_n : std_logic := '1';
signal ramp_delay_q      : std_logic_vector(ramp_delay_clocks - 2 downto 0) := (others => '1');
signal ramp_release_q    : natural range 0 to ramp_release_clocks := 0;
signal cb2_delay_q       : std_logic_vector(cb2_delay_clocks - 1 downto 0) := (others => '0');

signal dac       : signed(8 downto 0);
signal dac_z     : std_logic_vector(7 downto 0) := (others => '0');
signal dac_sound : std_logic_vector(7 downto 0);

signal integrator_x : signed(19 downto 0)  := (others => '0');
signal integrator_y : signed(19 downto 0)  := (others => '0');
signal cpu_phase    : unsigned(1 downto 0) := (others => '0');

signal ay_do      : std_logic_vector(7 downto 0);
signal ay_sound   : std_logic_vector(9 downto 0);
signal ay_ioa_out : std_logic_vector(7 downto 0);
signal ay_ioa_oe  : std_logic;
signal ay_reset_n : std_logic;


signal pot              : signed(7 downto 0);
signal compare          : std_logic;
signal players_switches : std_logic_vector(7 downto 0);

signal vectrex_bd_rate_div       : unsigned(7 downto 0)         := X"00";
signal vectrex_serial_bit_in     : std_logic;
signal vectrex_serial_bit_in_d   : std_logic;
signal vectrex_serial_data_shift : std_logic_vector(7 downto 0) := X"00";
signal vectrex_serial_bit_cnt    : unsigned(3 downto 0)         := X"0";
signal vectrex_serial_byte_rdy   : std_logic;
signal vectrex_serial_byte_out   : std_logic_vector(7 downto 0) := X"00";

signal audio_mix           : signed(11 downto 0);
signal audio_machine       : signed(10 downto 0);
signal audio_sum           : signed(11 downto 0);
signal audio_speech        : signed(9 downto 0);
signal audio_speech_scaled : signed(10 downto 0);
signal speech_reset        : std_logic;
signal speech_rdy          : std_logic;
signal sp0256_rdy          : std_logic;

type work_memory_t is array(0 to 1023) of std_logic_vector(7 downto 0);
signal work_memory : work_memory_t := (others => (others => '0'));
attribute ramstyle : string;
attribute ramstyle of work_memory : signal is "M10K, no_rw_check";

type ram_seed_state_t is (SEED_CAPTURE, SEED_LOW, SEED_HIGH, SEED_DONE);
signal ram_seed_state  : ram_seed_state_t := SEED_CAPTURE;
signal ram_seed        : std_logic_vector(15 downto 0);
signal reset_machine   : std_logic;
signal boot_reset_seen : std_logic := '0';
signal timestamp_seen  : std_logic := '0';
signal timestamp_ready : std_logic := '0';
signal timestamp_load  : std_logic;
signal random_start    : std_logic := '1';
signal random_reset    : std_logic;
signal random_seed     : std_logic_vector(31 downto 0);
signal random_data     : std_logic_vector(31 downto 0);

component random_xor is port (
	clock : in  std_logic;
	reset : in  std_logic;
	seed  : in  std_logic_vector(31 downto 0);
	lfsr  : out std_logic_vector(31 downto 0)
);
end component;
component mc6809 is port
(
	CLK   : in  std_logic;
	CLKEN : in  std_logic;

	riseE : out std_logic;
	fallE : out std_logic;

	riseQ  : out std_logic;

	Din  : in  std_logic_vector(7 downto 0);
	Dout : out std_logic_vector(7 downto 0);
	ADDR : out std_logic_vector(15 downto 0);
	RnW  : out std_logic;

	nIRQ   : in  std_logic;
	nFIRQ  : in  std_logic;
	nRESET : in  std_logic := '1'
);
end component mc6809;

component jt49_bus
generic (
	COMP             : std_logic_vector(2 downto 0) := "000";
	MUTE_NULL_PERIOD : integer := 1
);
port (
	rst_n   : in  std_logic;
	clk     : in  std_logic;
	clk_en  : in  std_logic;
	bdir    : in  std_logic;
	bc1     : in  std_logic;
	din     : in  std_logic_vector(7 downto 0);
	sel     : in  std_logic;
	dout    : out std_logic_vector(7 downto 0);
	sound   : out std_logic_vector(9 downto 0);
	A       : out std_logic_vector(7 downto 0);
	B       : out std_logic_vector(7 downto 0);
	C       : out std_logic_vector(7 downto 0);
	sample  : out std_logic;
	IOA_in  : in  std_logic_vector(7 downto 0);
	IOA_out : out std_logic_vector(7 downto 0);
	IOA_oe  : out std_logic;
	IOB_in  : in  std_logic_vector(7 downto 0);
	IOB_out : out std_logic_vector(7 downto 0);
	IOB_oe  : out std_logic
);
end component;

begin

-- TIMESTAMP's toggle commits both host words
timestamp_load <= (timestamp(32) xor timestamp_seen) and not timestamp_ready;
random_reset   <= random_start or timestamp_load;
random_seed    <= timestamp(31 downto 0) when timestamp_load = '1' else (others => '0');
random_source : random_xor port map (clock, random_reset, random_seed, random_data);

reset_machine <= reset when ram_seed_state = SEED_DONE else '1';
process(clock)
begin
	if rising_edge(clock) then
		random_start    <= '0';
		timestamp_seen  <= timestamp(32);
		timestamp_ready <= timestamp_ready or timestamp_load;
		boot_reset_seen <= boot_reset_seen or boot_reset;

		-- Main's first reset can follow an early standalone boot; warm resets retain RAM.
		if cart_download = '1' or (boot_reset = '1' and boot_reset_seen = '0') then
			ram_seed_state <= SEED_CAPTURE;
		elsif reset = '0' then
			case ram_seed_state is
				when SEED_CAPTURE =>
					if random_start = '0' and timestamp_load = '0' then
						ram_seed       <= random_data(15 downto 0) or X"0101";
						ram_seed_state <= SEED_LOW;
					end if;
				when SEED_LOW  => ram_seed_state <= SEED_HIGH;
				when SEED_HIGH => ram_seed_state <= SEED_DONE;
				when SEED_DONE => null;
			end case;
		end if;
	end if;
end process;

-- The schematic defines the separate RAMP and BLANK paths; the delay values
-- are approximations to real hardware's propagation/charge/discharge delays.
-- DAC, sample/hold, mux and ZERO: about 8 us [96 clocks at 12 MHz].
-- RAMP assertion: 8.5 us [204 clocks at 24 MHz].
-- RAMP release: 9.5 us [228 clocks at 24 MHz]; the extra 1 us [24 clocks]
-- models Q301's release tail.
-- Both CB2 blanking edges: 1 us [24 clocks at 24 MHz].
process (clock)
begin
	if rising_edge(clock) then
		cb2_delay_q <= cb2_delay_q(cb2_delay_q'high - 1 downto 0) & via_cb2_o;

		ramp_delay_q <= ramp_delay_q(ramp_delay_q'high - 1 downto 0) & via_pb_o(7);
		if ramp_delay_q(ramp_delay_q'high) = '0' then
			ramp_integrator_n <= '0';
			ramp_release_q    <= ramp_release_clocks;
		elsif ramp_release_q /= 0 then
			ramp_release_q <= ramp_release_q - 1;
		else
			ramp_integrator_n <= '1';
		end if;

		if clken_12 = '1' then
			delay_buffer(0) <= via_ca2_o & via_pb_o(2 downto 0) & via_pa_o;
			for i in delay_buffer'high downto 1 loop
				delay_buffer(i) <= delay_buffer(i-1) ;
			end loop;

			via_pa_o_d        <= delay_buffer(analog_delay_ticks)(7 downto 0);
			sh_dac            <= delay_buffer(analog_delay_ticks)(8);
			dac_mux           <= delay_buffer(analog_delay_ticks)(10 downto 9);
			zero_integrator_n <= delay_buffer(analog_delay_ticks)(11);
		end if;
	end if;
end process;

beam_x      <= integrator_x;
beam_y      <= integrator_y;
beam_z      <= dac_z;
beam_ce     <= clken_12;
beam_zero_n <= zero_integrator_n;
beam_on     <= cb2_delay_q(cb2_delay_q'high);

-- Sign-extend the 8-bit DAC code used by the deflection integrators.
dac <= signed(via_pa_o_d(7)&via_pa_o_d);

analog_frontend : entity work.vectrex_analog_frontend
port map
(
	clock        => clock,
	ce           => clken_12,
	dac_code     => dac,
	dac_raw      => via_pa_o_d,
	sh_n         => sh_dac,
	mux_sel      => dac_mux,
	ramp_n       => ramp_integrator_n,
	zero_n       => zero_integrator_n,
	intensity    => dac_z,
	sound        => dac_sound,
	integrator_x => integrator_x,
	integrator_y => integrator_y
);

-- Free-running enables keep machine timing independent of video scan timing.
process (clock)
begin
	if rising_edge(clock) then
		cpu_phase <= cpu_phase + 1;
		clken_12  <= '0';
		cpu_en    <= '0';
		if pause = '0' then
			if cpu_phase(0) = '0' then
				clken_12 <= '1';
			end if;
			if cpu_phase = 0 then
				cpu_en <= '1';
			end if;
		end if;
	end if;
end process;

--------------------------------------------------------------------

fixed_bios_rom : entity work.bios_rom
port map
(
	clk  => clock,
	addr => cpu_addr(12 downto 0),
	data => rom_fixed_do
);

factory_bios_rom : entity work.bios_factory_rom
port map
(
	clk  => clock,
	addr => cpu_addr(12 downto 0),
	data => rom_factory_do
);

rom_do <= rom_factory_do when bios_factory = '1' else rom_fixed_do;

cartridge : entity work.vectrex_cartridge
port map
(
	clock         => clock,
	download      => cart_download,
	download_wr   => cart_wr,
	download_addr => cart_addr,
	download_data => cart_data,
	backup_addr   => backup_addr,
	backup_data   => backup_data,
	backup_wr     => backup_wr,
	backup_q      => backup_q,
	flash_enabled => flash_enabled,
	flash_busy    => flash_busy,
	flash_changed => flash_changed,
	flash_sector  => flash_sector,
	cpu_strobe    => cpu_e_rise,
	cpu_addr      => cpu_addr,
	cpu_data_out  => cpu_do,
	cpu_rw        => cpu_rw,
	cpu_selected  => cart_cs,
	cpu_data_in   => cart_do,
	pb6_out       => via_pb_o(6),
	pb6_oe        => via_pb_oe(6),
	pb6_in        => cart_pb6,
	irq_n         => via_irq_n
);

process(clock)
	variable write_addr : unsigned(9 downto 0);
	variable write_data : std_logic_vector(7 downto 0);
	variable write_en   : std_logic;
begin
	if rising_edge(clock) then
		write_addr := unsigned(cpu_addr(9 downto 0));
		write_data := cpu_do;
		write_en   := ram_cpu_write;
		if cart_wr = '1' then
			write_addr := unsigned(cart_addr(9 downto 0));
			write_data := (others => '0');
			write_en   := '1';
		-- C87E/C87F receive timestamp-seeded odd values (Mathis Rosenhauer's idea).
		-- Warm resets retain these bytes; other RAM keeps its clear policy.
		elsif reset = '0' and cart_download = '0' and ram_seed_state = SEED_LOW then
			write_addr := to_unsigned(16#07E#, write_addr'length);
			write_data := ram_seed(7 downto 0);
			write_en   := '1';
		elsif reset = '0' and cart_download = '0' and ram_seed_state = SEED_HIGH then
			write_addr := to_unsigned(16#07F#, write_addr'length);
			write_data := ram_seed(15 downto 8);
			write_en   := '1';
		end if;
		if write_en = '1' then
			work_memory(to_integer(write_addr)) <= write_data;
		end if;

		if ram_cpu_write = '1' then
			ram_do <= cpu_do;
		else
			ram_do <= work_memory(to_integer(unsigned(cpu_addr(9 downto 0))));
		end if;
	end if;
end process;

--------------------------------------------------------------------

-- C800-CFFF: 1K RAM mirrored twice; D000-D7FF: VIA registers mirrored 128 times.
-- In the partially decoded D800-DFFF range both devices are selected. RAM wins
-- the read mux below, while writes reach both devices, matching the hardware.
-- E000-FFFF: system BIOS.
ram_cs <= '1' when cpu_addr(15 downto 13) = "110" and cpu_addr(11) = '1' else '0';
via_cs <= '1' when cpu_addr(15 downto 13) = "110" and cpu_addr(12) = '1' else '0';
rom_cs <= '1' when cpu_addr(15 downto 13) = "111" else '0';

ram_cpu_write    <= ram_cs and not cpu_rw and rQ and not reset_machine;
via_read         <= via_cs and cpu_rw;
via_write        <= via_cs and not cpu_rw;
via_write_accept <= via_write and cpu_e_rise;
t2_low_write     <= '1' when via_write_accept = '1' and cpu_addr(3 downto 0) = X"8" else '0';
t2_high_write    <= '1' when via_write_accept = '1' and cpu_addr(3 downto 0) = X"9" else '0';

-- Resolve the external pin level seen by the VIA for pins configured as inputs.
via_pa_i <= (via_pa_o and via_pa_oe) or (ay_do and not via_pa_oe);
via_pb_i <= (via_pb_o and via_pb_oe) or
	(('0'&cart_pb6&compare&"00000") and not via_pb_oe);
via_ca2_i <= via_ca2_o when via_ca2_oe = '1' else '0';
via_cb1_i <= via_cb1_o when via_cb1_oe = '1' else '0';
via_cb2_i <= via_cb2_o when via_cb2_oe = '1' else '0';
via_irq_n <= not via_irq;

cpu_di <= cart_do when cart_cs  = '1' else
			 ram_do  when ram_cs   = '1' else
			 via_do  when via_cs   = '1' else
			 rom_do  when rom_cs   = '1' else
			 cpu_bus_hold_q;

-- An undriven read retains the byte last driven by a device or CPU write.
process(clock)
begin
	if rising_edge(clock) then
		if cpu_e_fall = '1' then
			if cpu_rw = '1' then
				cpu_bus_hold_q <= cpu_di;
			else
				cpu_bus_hold_q <= cpu_do;
			end if;
		end if;
	end if;
end process;

-- Player controls, or the speech-accessory ready signal in speech mode.
players_switches <= not(rt_2&lf_2&dn_2&up_2&rt_1&lf_1&dn_1&up_1) when speech_mode = '0'
else                speech_rdy&speech_rdy&speech_rdy&speech_rdy & not(rt_1&lf_1&dn_1&up_1);

-- Compare the selected joystick axis with the current DAC value.
-- Both inputs use the VIA outputs before the beam-model delay.
with via_pb_o(2 downto 1) select
pot <=   pot_x_1 when "00",
		 pot_y_1 when "01",
		 pot_x_2 when "10",
		 pot_y_2 when others;

compare <= '1' when (pot(7)&pot) > signed(via_pa_o(7)&via_pa_o) else '0';

--------------------------------------------------------------------

main_cpu : mc6809
port map
(
	CLK    => clock,
	CLKEN  => cpu_en,
	nRESET => not (reset_machine or ptx_enable),

	riseE => cpu_e_rise,
	fallE => cpu_e_fall,
	riseQ => rQ,

	Din  => cpu_di,
	Dout => cpu_do_core,
	ADDR => cpu_addr_core,
	RnW  => cpu_rw_core,

	nIRQ  => via_irq_n,
	nFIRQ => not rt_1
);


via6522_inst : entity work.via6522
port map(
	clock    => clock,
	-- Vectrex VIA PHI2 is the inverse of the 6809 E clock.
	rising   => cpu_e_fall,
	falling  => cpu_e_rise,
	reset    => reset_machine,
	addr     => cpu_addr(3 downto 0),
	wen      => via_write,
	ren      => via_read,
	data_in  => cpu_do,
	data_out => via_do,
	port_a_o => via_pa_o,
	port_a_t => via_pa_oe,
	port_a_i => via_pa_i,
	port_b_o => via_pb_o,
	port_b_t => via_pb_oe,
	port_b_i => via_pb_i,
	ca1_i    => not rt_2,
	ca2_o    => via_ca2_o,
	ca2_i    => via_ca2_i,
	ca2_t    => via_ca2_oe,
	cb1_o    => via_cb1_o,
	cb1_i    => via_cb1_i,
	cb1_t    => via_cb1_oe,
	cb2_o    => via_cb2_o,
	cb2_i    => via_cb2_i,
	cb2_t    => via_cb2_oe,
	irq      => via_irq
);

-- Report accepted Timer 2 loads to the external frame-boundary detector.
process(clock)
begin
	if rising_edge(clock) then
		t2_reload <= '0';
		if reset_machine = '1' then
			t2_low_q  <= (others => '0');
			t2_period <= (others => '0');
		elsif t2_low_write = '1' then
			t2_low_q <= cpu_do;
		elsif t2_high_write = '1' then
			t2_reload <= '1';
			t2_period <= cpu_do & t2_low_q;
		end if;
	end if;
end process;

-- sound

ay_reset_n <= not reset_machine;

-- PiTrex mode bus mux (see port comment).
cpu_addr  <= ptx_addr when ptx_enable = '1' else cpu_addr_core;
cpu_do    <= ptx_do   when ptx_enable = '1' else cpu_do_core;
cpu_rw    <= ptx_rw   when ptx_enable = '1' else cpu_rw_core;
e_fall_o  <= cpu_e_fall;
psg_ioa_o <= players_switches;

ay_3_8912 : jt49_bus
generic map(
	COMP             => "000",
	MUTE_NULL_PERIOD => 0 -- AY period zero behaves as period one
)
port map(
	rst_n   => ay_reset_n,
	clk     => clock,
	clk_en  => rQ,
	bdir    => via_pb_o(4),
	bc1     => via_pb_o(3),
	din     => via_pa_o,
	sel     => '1', -- rQ is already the 1.5 MHz PSG clock enable
	dout    => ay_do,
	sound   => ay_sound,
	A       => open,
	B       => open,
	C       => open,
	sample  => open,
	IOA_in  => players_switches,
	IOA_out => ay_ioa_out,
	IOA_oe  => ay_ioa_oe,
	IOB_in  => (others => '0'),
	IOB_out => open,
	IOB_oe  => open
);

audio_mix <=
	resize(signed('0' & ay_sound), audio_mix'length) +
	shift_left(resize(signed(dac_sound), audio_mix'length), 2) +
	shift_left(resize(signed(dac_sound), audio_mix'length), 1);
audio_machine <= resize(shift_right(audio_mix, 2), audio_machine'length);

with speech_level select
	audio_speech_scaled <=
		resize(audio_speech, audio_speech_scaled'length) +
			shift_right(resize(audio_speech, audio_speech_scaled'length), 1) when "00",
		resize(audio_speech, audio_speech_scaled'length) when "01",
		shift_left(resize(audio_speech, audio_speech_scaled'length), 1) when others;

audio_sum <=
	    resize(audio_machine, audio_sum'length) +
	    resize(audio_speech_scaled, audio_sum'length) when speech_mode = '1' else
	    resize(audio_machine, audio_sum'length);

audio_out <=
	    to_signed( 511, audio_out'length) when audio_sum >  511 else
	    to_signed(-512, audio_out'length) when audio_sum < -512 else
	    audio_sum(audio_out'range);

-- VecVoice data is PSG port A bit 4 when driven, with a high idle level when
-- the port returns to input mode. Port A bit 5 carries the ready response.
vectrex_serial_bit_in <= ay_ioa_out(4) when ay_ioa_oe = '1' else '1';
speech_reset          <= reset_machine or not speech_mode;

-- Decode the speech serial stream carried by PSG port A direction changes.
process (clock)
begin
	if rising_edge(clock) then
		if speech_reset = '1' then
			vectrex_bd_rate_div       <= X"00";
			vectrex_serial_bit_in_d   <= '1';
			vectrex_serial_data_shift <= X"00";
			vectrex_serial_bit_cnt    <= X"0";
			vectrex_serial_byte_rdy   <= '0';
			vectrex_serial_byte_out   <= X"00";
		elsif rQ = '1' then
			vectrex_serial_bit_in_d <= vectrex_serial_bit_in;

			if vectrex_serial_bit_in /= vectrex_serial_bit_in_d then -- reset baud counter on either edge
				vectrex_bd_rate_div <= X"00";
			else
				if vectrex_bd_rate_div = X"9B" then -- 1.5 MHz / 156 = 9.615 kbaud
					vectrex_bd_rate_div <= X"00";
				else
					vectrex_bd_rate_div <= vectrex_bd_rate_div + 1;
				end if;
			end if;

			if vectrex_bd_rate_div = X"4E" then
				vectrex_serial_data_shift <=  vectrex_serial_bit_in  & vectrex_serial_data_shift(7 downto 1); -- VecVoice/VecVox data is LSB-first.

				if vectrex_serial_bit_cnt = X"0" and vectrex_serial_bit_in = '0' then
					vectrex_serial_bit_cnt  <= X"1";
					vectrex_serial_byte_rdy <= '0';
				end if;

				if vectrex_serial_bit_cnt > X"0" then
					vectrex_serial_bit_cnt <= vectrex_serial_bit_cnt + 1;
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
end process;

-- 24 MHz / 96 provides the SP0256's 250 kHz state-machine enable.
process (clock)
begin
	if rising_edge(clock) then
		if reset_machine = '1' then
			speech_enable_count <= (others=>'0');
			ce_250k    <= '0';
		else
			ce_250k <= '0';
			if pause = '0' then
				if speech_enable_count >= 95 then
					speech_enable_count <= (others=>'0');
					ce_250k    <= '1';
				else
					speech_enable_count <= speech_enable_count + 1;
				end if;
			end if;
		end if;
	end if;
end process;

-- Optional SP0256-AL2 speech synthesizer.
speech_rdy <= not sp0256_rdy;

sp0256 : entity work.sp0256
port map
(
	clock => clock,
	ce    => ce_250k,
	reset => speech_reset,

	input_rdy      => sp0256_rdy,
	allophone      => vectrex_serial_byte_out(5 downto 0),
	trig_allophone => vectrex_serial_byte_rdy,

	audio_out      => audio_speech
);

end SYN;
