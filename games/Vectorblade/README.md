# Vectorblade v1.13

Vectorblade by **Malban** is included with the author's permission. The game
ROM and original overlay retain their authors' rights; inclusion here does
not relicense them under the FPGA core's licenses.

## Installation

Copy `Vectorblade (v1.13).bin` and `Vectorblade (v1.13).art` from this folder to
`/media/fat/games/Vectrex/`, then load the ROM. The Normal overlay loads
automatically because its basename matches the ROM.

For a rotated display, select the matching Orientation in the core menu and
load `VectorbladeV1.13_90CW.art` or `VectorbladeV1.13_90CCW.art` from
the `Tate` folder in [overlays.zip](../../overlays/overlays.zip) through
**Load Overlay**. To make that orientation load automatically, use a copy of
the selected package named `Vectorblade (v1.13).art` beside the ROM instead.

See [Overlays](../../README.md#vectrex-overlays) for loading and brightness controls,
or [Overlay Tools](<../../Overlay Tools/README.md>) to create your own artwork.

## Calibration

On the model-selection screen, choose **Buzz**. At the text-calibration screen,
move the joystick until the text is aligned as closely as possible.

Later, the game displays what it calls a swarm element of the Queen. This
"little fellow" cannot be aligned perfectly; adjust it only to the appearance
you prefer. It is a matter of taste rather than another exact alignment test.

Calibration only needs to be performed once. Vectorblade stores the result in
its cartridge flash memory, which the core preserves in the persistent `.sav`
file described below.

## Saving

Vectorblade manages its own records in cartridge flash. The core persists
changed sectors to `Vectorblade (v1.13).sav` in MiSTer's Vectrex saves directory
and restores them before starting the game.

Cartridge Autosave defaults to On. Wait until the user LED goes out before
switching games or powering off. With Autosave off, use **System > Save
Cartridge**. This saves only records the game has written to flash, not an
arbitrary running game state. Console reset preserves flash and pending saves.

Back up important saves. Invalid checksums or a different ROM revision are
rejected; an interrupted physical disk write cannot be made power-loss safe
by the core alone.

## Sources

- [Vectorblade source and releases](https://github.com/malbanGit/Vectorblade)
- [Original V4 overlay](https://github.com/malbanGit/Vectorblade/blob/master/other/overlay/VB-Overlay-V4.eps)
- MiSTer overlay conversion and cartridge integration: Videodr0me.

ROM SHA-256:
`4b3866939ec90c7fda4377f7d09de202b848dbca0fa14019b4c728bfb8d20c0e`.
