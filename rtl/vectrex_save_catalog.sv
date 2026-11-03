// Per-cartridge save hardware and RAM score layouts.
// Four-bank SST flash (Vectorblade and Telengard) is selected by the cartridge mapper.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later

package vectrex_save_catalog;
	// Header byte 28 stores the EEPROM or score-layout ID. Keep assigned values stable for saved games.
	localparam logic [2:0] EE_NONE = 0, EE_UNIO = 1, EE_I2C = 2, EE_DS2430A = 3, EE_DS2431 = 4;
	localparam logic [2:0] SCORE_NONE = 0, SCORE_BIOS = 1, SCORE_TEAM = 2,
	                       SCORE_RACE = 3, SCORE_BIRD = 4, SCORE_AGON = 5;

	// Match the seven-bit title characters at the stated ROM offset and check the ROM size.
	// Vector Pilot selects I2C only if its eight driver bytes also match. Otherwise it uses UNI/O.
	function automatic [294:0] eeprom(input logic [15:0] offset, input logic [16:0] capacity,
	                                  input logic [2:0] device, alternate, input logic [255:0] title);
		return {alternate, offset, capacity, device, title};
	endfunction
	localparam EEPROM_ROMS = {
		eeprom(16'h8011, 17'd65536, EE_UNIO,    EE_I2C,  "VECTOR PILOT"),
		eeprom(16'h8011, 17'd65536, EE_I2C,     EE_NONE, "VECTOR PATROL"),
		eeprom(16'h0011, 17'd32768, EE_DS2430A, EE_NONE, "THRUST FOR VECTREX"),
		eeprom(16'h0011, 17'd32768, EE_DS2431,  EE_NONE, "KARL QUAPPE"),
		eeprom(16'h0011, 17'd32768, EE_DS2431,  EE_NONE, "RELEASE"),
		eeprom(16'h0011, 17'd32768, EE_DS2431,  EE_NONE, "ROCKS"), // Rocks 'n' Saucers, first title line.
		eeprom(16'h0011, 17'd32768, EE_DS2431,  EE_NONE, "PUCK! V0.53DS")
	};
	// Pilot's I2C release has this eight-byte VIA access sequence in the first bank.
	localparam logic [15:0] PILOT_I2C_OFFSET = 16'h7ebf;
	localparam logic [63:0] PILOT_I2C_CODE   = 64'hc60ed7040f05c618;

	// RAM entries match the exact downloaded byte count and standard CRC32.
	// The layout selects the game's score addresses, write order and startup event.
	function automatic [50:0] ram_save(input logic [15:0] size, input logic [31:0] crc,
	                                   input logic [2:0] layout_id);
		return {size, crc, layout_id};
	endfunction
	localparam SCORE_ROMS = {
		ram_save(16'd8192,  32'h92709b11, SCORE_BIOS), // 3D Crazy Coaster
		ram_save(16'd8192,  32'hb2313487, SCORE_BIOS), // 3D Mine Storm
		ram_save(16'd8192,  32'h050bd949, SCORE_BIOS), // 3D Narrow Escape
		ram_save(16'd4096,  32'hb7510971, SCORE_BIOS), // Armor Attack
		ram_save(16'd4096,  32'ha2fa649b, SCORE_BIOS), // Bedlam
		ram_save(16'd4096,  32'heafe2455, SCORE_BIOS), // Berzerk
		ram_save(16'd8192,  32'h0f11ce0c, SCORE_TEAM), // Blitz!
		ram_save(16'd4096,  32'hf1b1de78, SCORE_BIOS), // Clean Sweep
		ram_save(16'd4096,  32'h6c1afa52, SCORE_BIOS), // Cosmic Chasm
		ram_save(16'd12288, 32'h9dcfd5b7, SCORE_BIOS), // Dark Tower
		ram_save(16'd8192,  32'h13a35c8a, SCORE_BIOS), // Fortress of Narzod
		ram_save(16'd8192,  32'he61a7de3, SCORE_TEAM), // Heads Up
		ram_save(16'd4096,  32'h4bb13472, SCORE_BIOS), // Hyperchase
		ram_save(16'd8192,  32'hda1ac0db, SCORE_BIOS), // Mail Plane
		ram_save(16'd8192,  32'hafefa29c, SCORE_BIOS), // Melody Master
		ram_save(16'd4096,  32'hf5b3b374, SCORE_BIOS), // Mine Storm II cartridge
		ram_save(16'd8192,  32'ha7471784, SCORE_BIOS), // Polar Rescue
		ram_save(16'd8192,  32'hc10f37d8, SCORE_BIOS), // Pole Position
		ram_save(16'd4096,  32'h34a98132, SCORE_BIOS), // Rip Off
		ram_save(16'd4096,  32'h707c8ffe, SCORE_BIOS), // Scramble
		ram_save(16'd4096,  32'h5c4611c8, SCORE_BIOS), // Solar Quest
		ram_save(16'd8192,  32'h62a61843, SCORE_BIOS), // Spike
		ram_save(16'd8192,  32'h02f41733, SCORE_BIOS), // Spinball
		ram_save(16'd4096,  32'hc9039623, SCORE_BIOS), // Star Castle
		ram_save(16'd4096,  32'h4de1f06b, SCORE_BIOS), // Star Hawk
		ram_save(16'd4096,  32'h7967a8cb, SCORE_BIOS), // Star Ship
		ram_save(16'd4096,  32'h3768d8c3, SCORE_BIOS), // Star Trek
		ram_save(16'd8192,  32'hbb4791f1, SCORE_RACE), // Tour de France
		ram_save(16'd8192,  32'h521107c3, SCORE_BIOS), // Web Warp
		ram_save(16'd8192,  32'h2ee20103, SCORE_BIOS), // Web Wars
		ram_save(16'd5649,  32'hf2c6e043, SCORE_BIRD), // Veccy Bird
		ram_save(16'd24685, 32'hbcc8e15b, SCORE_AGON)  // Vectrexagon
	};
	localparam integer EEPROM_COUNT = $bits(EEPROM_ROMS) / 295;
	localparam integer SCORE_COUNT  = $bits(SCORE_ROMS) / 51;
endpackage
