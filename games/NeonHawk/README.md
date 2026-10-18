# Neon Hawk Demo v1.0

Neon Hawk by **Jaakko and Mikko Huovinen** is a 3D rail shooter for the Vectrex.
The v1.0 demo is included with permission. The ROM and original artwork retain
their authors' rights; inclusion here does not relicense them under the FPGA
core's licenses.

## Installation

Copy `Neon Hawk Demo (v1.0).bin` and `Neon Hawk Demo (v1.0).art` from this folder
to `/media/fat/games/Vectrex/`, then load the ROM. The Normal overlay loads
automatically because its basename matches the ROM.

The supplied artwork is the same package as `Neon_Hawk.art` in
[overlays.zip](../../overlays/overlays.zip).

For a rotated display, select the matching Orientation in the core menu and
load `Neon_Hawk_90CW.art` or `Neon_Hawk_90CCW.art` from the archive's `Tate`
folder through **Load Overlay**. For automatic loading, rename a copy of the
chosen package to `Neon Hawk Demo (v1.0).art` beside the ROM.

## How to Play

Shoot enemies and Neon Rocks, collect Neon Cells to replenish energy, jump
over obstacles, and avoid walls. Use the Sky Cannon to shoot down bombers.

| Action | Control |
| --- | --- |
| Move | Joystick left/right |
| Fire | Hold Button 1 or Button 4 |
| Short jump | Tap Button 2 |
| Long jump | Hold and release Button 2 |
| Side jump | Joystick left/right while tapping Button 2 |
| Sky Cannon | Hold Button 3 to activate and fire; release to exit |

These controls follow the demo's original `controls.txt`.

## Sources and Credits

- Game: **Jaakko and Mikko Huovinen**.
- [Demo announcement and original download](https://www.reddit.com/r/Vectrex/comments/1t854ud/new_trailer_for_neon_hawk/).
- [Developer interview in Skrolli 2025.4 (Finnish, PDF)](https://skrolli.fi/2025.4.turrikaani.pdf).
- Original artwork: supplied with the demo; MiSTer ART conversion by Videodr0me.

The 64 KiB ROM is an unchanged copy of `Neon_Hawk_demo_v1_0.bin` from the
original demo archive, renamed to match the bundled artwork.

ROM SHA-256:
`33228dd408c56f462f87204009e74d9d5bbb5af936e4dd0dc791def26f3e0e1f`.
