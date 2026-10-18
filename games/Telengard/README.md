# Telengard v1.03

Telengard by **Malban** (2022/2026) is a homebrew Vectrex port of the classic 1982
dungeon crawler originally created by **Daniel M. Lawrence**. It features a 256 KiB
four-bank flash cartridge design with persistent character saves.

## Installation

Copy `Telengard (v1.03).bin` and `Telengard (v1.03).art` from this folder
to `/media/fat/games/Vectrex/`, then load the ROM. The artwork loads
automatically because its basename matches the ROM.

Telengard was originally designed as a pure vector CRT title without a physical
overlay. The optional digital overlay supplied here was created for this
project. It is also included as `Telengard.art` in
[overlays.zip](../../overlays/overlays.zip).

## Calibration

On the title screen, press **Button 3** to enter the calibration menu:

- Press **Button 1** to select **Buzz** (the calibrated model for this core).
- Press **Button 2** for **No Buzz**.
- Move the **joystick left or right** to adjust calibration.
- Press **Button 4** to save and exit calibration.

The calibration setting is saved to cartridge flash and restored automatically on
subsequent launches.

## Saving

Telengard supports persistent character saving at any **Inn** in the dungeon.
Saved characters and progress are written to cartridge flash and automatically
persisted by the core to `Telengard (v1.03).sav` in MiSTer's Vectrex saves directory.

Cartridge Autosave defaults to On. Wait until the user LED goes out before switching
games or powering off. With Autosave off, use **System > Save Cartridge** in the core
menu. Console reset preserves flash contents and pending saves.

## Controls and Interface

Telengard operates in real time: if no action is chosen, the game auto-advances
approximately every 5 seconds. Pressing any button or joystick direction breaks the
pause.

### Exploration

- **Joystick**: Character movement.
- **Button 1**: Go UP (when on a staircase).
- **Button 4**: Go DOWN (when on a staircase).
- **Button 2**: Enter the 5-page **Status Screen**.
- **Button 3**: Enter the **Spell Casting Screen**.

### Status Screen (`<2>`)

Navigate through 5 pages using the joystick:

1. **STATS**: Character attributes, current dungeon level, and hitpoints.
2. **ENV**: Current dungeon location, room environment, and monster encounters.
3. **VARS**: Level, spell units, experience points, and tavern gold.
4. **MODS**: Inventory and equipment modifiers (armor, shield, boots, cloak, etc.).
5. **ITEMS**: Usable items (Scroll of Rescue, Potion of Healing, Potion of Strength).
   Select an item with the joystick and press **Button 4** to deploy it.

### Spell Casting (`<3>`)

- Navigate spell levels using the joystick.
- Select an available spell and press **Button 2**, **Button 3**, or **Button 4** to cast.
- Press **Button 1** to cancel casting.

### Sub-Screens

- **Box**: Select color using the joystick.
- **Cube**: Input dungeon level using number selection via joystick.
- **Throne**: Select gold amount using joystick.

## Sources and Credits

- Original game by **Daniel M. Lawrence** (1982).
- Vectrex port and flash architecture by **Malban** (2022/2026).
- [Telengard source repository](https://github.com/malbanGit/Telengard)
- [Original game manual](https://www.orphanedgames.com/articles/Telengod/downloads/telengard-manual.pdf)

ROM SHA-256:
`2d00dcf65765c96f77d177a362ae7dbb84158e1ac465a826c08a99764a529c78`.
