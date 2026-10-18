-- Based on Dar's DAC, sample-and-hold and integrator model.
-- Current REF acquisition and saturating integrators by Videodr0me.
-- SPDX-License-Identifier: GPL-2.0-or-later
-- Values update on the 12 MHz enable; REF models finite sample
-- acquisition, while ZERO clears and RAMP advances the integrators.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vectrex_analog_frontend is
	port
	(
		clock        : in  std_logic;
		ce           : in  std_logic;
		dac_code     : in  signed(8 downto 0);
		dac_raw      : in  std_logic_vector(7 downto 0);
		sh_n         : in  std_logic;
		mux_sel      : in  std_logic_vector(1 downto 0);
		ramp_n       : in  std_logic;
		zero_n       : in  std_logic;
		intensity    : out std_logic_vector(7 downto 0);
		sound        : out std_logic_vector(7 downto 0);
		integrator_x : out signed(19 downto 0);
		integrator_y : out signed(19 downto 0)
	);
end entity;

architecture rtl of vectrex_analog_frontend is
	constant ref_frac_bits    : natural                      := 8;
	constant int_max_q        : integer                      := 524287 * 2**ref_frac_bits;
	constant int_min_q        : integer                      := -524288 * 2**ref_frac_bits;
	signal held_y             : signed(8 downto 0)           := (others => '0');
	signal held_ref_q         : signed(15 downto 0)          := (others => '0');
	signal held_z, held_sound : std_logic_vector(7 downto 0) := (others => '0');
	signal x_q, y_q           : signed(27 downto 0)          := (others => '0');

	function acquire_ref(value, target : signed(15 downto 0)) return signed is
		variable delta, step : signed(16 downto 0);
	begin
		delta := resize(target, 17) - resize(value, 17);
		-- Alpha 1/8 at 12 MHz models a 0.624 us REF acquisition time constant.
		step := shift_right(delta, 3);
		if delta > 0 and step = 0 then
			step := to_signed(1, 17);
		end if;
		return resize(resize(value, 17) + step, 16);
	end function;

	function saturate_integrator(value : signed(28 downto 0)) return signed is
	begin
		if value > int_max_q then
			return to_signed(int_max_q, 28);
		elsif value < int_min_q then
			return to_signed(int_min_q, 28);
		else
			return value(27 downto 0);
		end if;
	end function;
begin
	process(clock)
		variable ref_target : signed(15 downto 0);
	begin
		if rising_edge(clock) then
			if ce = '1' then
				if sh_n = '0' then
					case mux_sel is
						when "00"   => held_y     <= dac_code;
						when "01"   =>
							ref_target := shift_left(resize(dac_code, 16), ref_frac_bits);
							held_ref_q <= acquire_ref(held_ref_q, ref_target);
						when "10"   => held_z     <= dac_raw;
						when others => held_sound <= dac_raw;
					end case;
				end if;

				if zero_n = '0' then
					x_q <= (others => '0');
					y_q <= (others => '0');
				elsif ramp_n = '0' then
					x_q <= saturate_integrator(resize(x_q, 29) +
					                           resize(held_ref_q, 29) -
					                           shift_left(resize(held_y, 29), ref_frac_bits));
					y_q <= saturate_integrator(resize(y_q, 29) -
					                           resize(held_ref_q, 29) +
					                           shift_left(resize(dac_code, 29), ref_frac_bits));
				end if;
			end if;
		end if;
	end process;

	intensity    <= held_z;
	sound        <= held_sound;
	integrator_x <= x_q(27 downto ref_frac_bits);
	integrator_y <= y_q(27 downto ref_frac_bits);
end architecture;
