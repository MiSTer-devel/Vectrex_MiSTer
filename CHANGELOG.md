# Changelog

For earlier changes, see the
[commit history](https://github.com/MiSTer-devel/Vectrex_MiSTer/commits/945088b8862c09aa556f3d0c3efa07eeaa1a5b5b/).

## Enhanced Core Rebuild v1.0 [2026-10-18]

- Added a new 125 MHz HD rasterizer supporting multiple target resolutions,
  including 1080p and 720p at 120 Hz, with optional HDR output and CRT-effects support.
- Added a CRT-effects pipeline with bloom, broad halo, beam modeling,
  intra-frame and inter-frame decay, tone mapping, custom color options,
  overlay tint, and phosphor accumulation.
- Added comprehensive CRT support: 480p, 480i, 240p, Direct Video at 15 kHz
  and 31 kHz, CRT-friendly timings covering a broad range of displays,
  and a vertical offset control for positioning the complete picture.
- Added a new beam model with dwell energy accumulation, line brightness
  that responds to beam velocity, and energy accumulation at beam crossings.
  Linear light processing preserves an extended brightness range, with
  intense colored highlights gradually spilling toward white.
- Corrected MC6809 NMI arming, reset interrupt state, and `SEX` flag behavior.
- Replaced the VIA with Gideon Zweijtzer's more accurate 6522 model and
  corrected Vectrex half-cycle timing, Timer 1 sequencing, interrupt readback,
  and complete eight-bit shift output, restoring Clean Sweep characters and
  complete bitmap glyphs.
- Modeled Q301 RAMP release and uniform CB2 beam-blanking timing, improving
  the rendering of Clean Sweep's maze walls and eliminating clipped or
  wobbly strokes in Spike's EEK, HELP, SPIKE, and MOLLY raster text.
- Modeled reference sample-and-hold acquisition, fixing Vectorblade's
  calibration mode (Buzz model).
- Initialized the BIOS random-seed bytes from the HPS timestamp at cold start
  while retaining RAM across warm resets, restoring natural variation in Mine
  Storm's initial starfield.
- Modeled last-driven CPU open-bus behavior and correct no-cartridge decoding,
  preventing the built-in Mine Storm malformed-vector display glitch.
- Reworked EOF detection around a dynamic model of Timer 2 activity that
  learns redraw cadence, with a fallback mode if qualified reloads stop and
  a replacement scheme during recurring fallback until reloads resume.
- Added HD digital overlays that recreate the Vectrex's physical screen
  overlays, with automatic or manual loading, resolution-specific
  1080p/720p/480p/240p planes, all three orientations, and independent Tint
  Strength, Translucent Blend, and Opaque Brightness controls.
- Included 65 overlay designs in `overlays/overlays.zip`, with standard
  artwork at the archive root and clockwise/counterclockwise versions in
  `Tate`. The collection includes restored artwork, alternatives, and a full-width
  Mine Storm strategy bezel as an example of a custom oversized overlay.
- Added documented host-side tools in `Overlay Tools` that build all resolutions and
  orientations from one PNG, pack authored planes and extract PNGs from ART
  packages, with palette reduction and package validation.
- Expanded display geometry with Normal, 90 CCW, and 90 CW orientations,
  Overlay or Screen framing, and an Open Matte view that reveals geometry
  drawn outside the normally visible area.
- Speech: corrected SP0256 speech saturation, idle output, and PSG Port A
  serial decoding. Port 2 device isolation prevents retained 3D-imager traffic
  in Narrow Escape 2D from triggering speech, with selectable Normal, Low,
  and High speech levels.
- Sound: replaced AY-3-8912 emulation with JT49 and corrected direct CPU DAC
  audio to signed samples matching the Vectrex MC1408 path.
- Calibrated PSG and direct-DAC balance against a real Vectrex line-out
  recording.
- Added 64 KiB PB6 cartridge banking (e.g. Vector Patrol) and the 256 KiB
  four-bank mapper used by Vectorblade and Telengard.
- Added SST39SF020A flash programming and sector erase, with per-ROM
  persistent storage, automatic restore, default-on autosave, manual saving,
  and ROM/sector checksum validation.
- Added resolution-specific CRT presets, with Cruise Control as the default.
  Custom 1 and Custom 2 expose the effects controls and use the active
  resolution's Cruise Control and Overdrive presets as their starting points.
- Added a remappable View button that cycles artwork, framing, and Open Matte
  combinations, with an on-screen message and matching OSD settings.
- Added pause mode with screen dimming after 60 seconds and an option to
  pause while the OSD is open.

The core requires a 32 MB SDRAM module or larger.
