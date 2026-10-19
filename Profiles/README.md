# Video Settings and Profiles

Each fixed profile has separate settings for 240p, 480p/480i, 720p and 1080p.
The 720p settings also apply at 120 Hz. Cruise Control is the default for new
or reset settings. Choose a fixed profile for a ready-made look, or copy one
into [Custom 1 or Custom 2](#custom-profiles) to adjust it to your taste.

Artwork controls, Beam Threshold and diagnostic settings apply to every
profile. They do not change when you select or copy a profile.

## Fixed Profiles

Select a profile under **Video Profiles & Effects** in the OSD.
With the OSD closed, press the **=/+** key to activate the next profile or
the **-** key to return to the previous profile. No Shift is needed. A small
on-screen message shows which profile is now active. These are the two keys
immediately to the right of **0** on a US keyboard; use the same physical
keys on other layouts.

Some profile changes may briefly interrupt HDMI output while the display
resynchronizes.

- **80s Cruise Control:** The default after Reset Settings, with familiar
  vector CRT glow, richer halo and stronger bloom.
- **80s Overdrive:** Hot vectors, heavy bloom and lingering phosphor trails.
- **Neon Blue:** Electric blue vectors that turn white at their brightest,
  with a subdued blue halo and lingering phosphor trails.
- **Red Alert:** Red phosphor with strong bloom and halo, plus long trails.
- **Ultraviolet:** Purple phosphor with strong halo and medium or long trails,
  depending on resolution.
- **A Touch of CRT:** Subtle halo and bloom while vectors remain crisp.

The menu and keyboard shortcuts cycle through Cruise Control -> Overdrive ->
Neon Blue -> Red Alert -> Ultraviolet -> Custom 1 -> Custom 2 -> A Touch of CRT ->
Cruise Control.

Red Alert and Ultraviolet can produce intense flashing and should not be used
by anyone sensitive to it.

## Custom Profiles

After Reset Settings, activating either custom profile for the first time
copies the presets for the current output resolution into both slots:
Cruise Control into Custom 1 and Overdrive into Custom 2. For example,
activating Custom 1 at 1080p gives it Cruise Control's 1080p settings. These
selections stay in the custom slots when you change resolution. Once saved
through MiSTer's menu, they are restored on future starts even if the core
starts at a different resolution.

To use any profile as a starting point:

1. Select the profile whose appearance is closest to what you want.
2. Close the OSD, hold **Ctrl+Shift**, and press **1** or **2** on the number
   row to copy it into Custom 1 or Custom 2. A message confirms the copy.
3. Select that custom profile and adjust its controls. Copying does not
   automatically switch the active profile.
4. Save the core settings through MiSTer's menu to keep your custom profiles
   for the next session.

Copying into a custom slot replaces that slot's settings. Artwork controls
and Beam Threshold keep their current settings when you copy a profile.

## Adjusting a Custom Profile

The controls below are available when Custom 1 or Custom 2 is selected.

| Control | Effect |
|---|---|
| **Dwell Low Size** | Sets the size of smaller high-intensity dwells, including those inside Mine Storm's mines. Higher settings increase their spread. |
| **Dwell Mid Growth** | Adds size to stronger dwells, such as Mine Storm's spores. |
| **Dwell High Growth** | Adds size to the most intense dwells, such as Mine Storm's bullet. |
| **Brightness** | Selects a subdued, balanced, bright or strongly boosted picture. Higher settings also make bright colors turn toward white sooner. |
| **Bloom Width** | Sets how far the close glow extends around lines and high-intensity dwells. Narrow settings keep a crisp outline; wider settings give thicker lines and a softer glow. Off removes bloom. |
| **Bloom Curve** | Controls how strongly beam energy excites local bloom. |
| **Halo** | Sets the strength of the broad glow around bright objects. Off removes this glow. |
| **Halo Curve** | Controls how strongly beam energy excites the broad halo. |
| **Halo Spread** | Shapes the broad glow. Focus keeps it closer to objects; Original is wider, and Wide 1 and Wide 2 spread it farther. |
| **Halo Compression** | Compresses bright halo peaks. Lower numeric choices begin compression earlier and act more strongly; Off leaves the halo uncompressed. |
| **Halo Grid** | The finer 8x8 grid helps keep the halo localized around bright objects; 16x16 gives a broader glow. Compare both at your current output resolution and with your chosen Halo Spread. |
| **Inter-Frame Decay** | Sets how long the phosphor retains previous images. Short gives a brief afterglow; Medium and Long leave more visible trails behind moving objects. Off removes these trails. |
| **Intra-Frame Decay** | The core tracks each individual pixel's draw age relative to the other pixels within one frame. This setting makes earlier pixels fade more than later ones. LUT A is subtle, LUT C is stronger, and LUT B is strongest. Off disables intra-frame decay for a stable image. |
| **Vector Color** | Chooses the beam color: Vectrex P4, Deluxe Blue, White, Red, Purple, Cyan or Blue. Bright highlights can turn toward white. |

Tuning a profile is an iterative process: Brightness, Vector Color, dwell
size, bloom and halo all affect the result. Halo also adds brightness to the
vectors themselves, so revisit the balance as you adjust each setting. Use
decay to set how long the glow lingers.

### Brightness and Beam Threshold

The brightness modes adjust the final appearance of the vectors and their
glow, from subdued to intense.

| Brightness | What you will see |
|---|---|
| **Reduced** | A subdued presentation that trades dynamic range for saturation. |
| **Standard** | The balanced reference presentation. |
| **Bright** | Brighter lines and glow, with highlights reaching white sooner. |
| **Boost** | The most intense look, with aggressive white spill that pushes strong colored highlights quickly toward white. |

White spill is the shift from the selected beam color toward white in bright
areas, just like on a real Vectrex. For example, a red highlight can become
pale pink and then white. Its appearance also depends on the vector color
and any artwork tint.

**Beam Threshold** (System menu) sets the beam cutoff for all profiles.
Real Vectrex consoles are typically calibrated to cut off between **Z 20**
and **Z 28**. Choose **Z 20** (default), **Z 24**, **Z 28** or **Off**.
The selected Z level is the lowest accepted for drawing; lower levels are
hidden. Off accepts all positive Z levels and can reveal normally hidden
faint lines. The accepted range is rescaled, reaching full source intensity
at **Z 127**.

### Dwell size controls

When the beam lingers in one place, it can produce much more light than a
moving line. On a real Vectrex these high-intensity dwells spread over an
area; the core reproduces that growth for bright stars, spores and bullets.
Start with **Low Size**, then adjust **Mid Growth** and **High Growth** to
decide how much larger the stronger dwells become.

Low Size offers levels 1 to 8; these are not pixel dimensions. The Growth
controls offer Same and +1 through +7 as relative growth levels, not fixed
percentages. Same keeps that stage at the preceding size; higher choices add
more growth. Changing Low Size also affects the stronger dwells. The core
uses Hermite interpolation for smooth, resolution-dependent sizing, up to
a centered 5 x 5 pixel footprint.

Dwell sizing mainly compensates for differences in pixel size between output
resolutions. Your custom profile keeps the selected menu levels when you
change resolution, but you can adjust them again to suit the display. Larger
dwells can also make the surrounding glow more prominent, so check bloom and
halo after changing their size.

### Bloom and halo

Bloom primarily widens lines, adding a close glow that softens the edges of
lines and high-intensity dwells. Halo is the much broader pool of light around
bright objects.

For bloom, start with **Bloom Width: Tight** and **Bloom Curve: Mild+**. Raise
the curve first. If the lines still look too thin, or become too bright
before reaching the desired thickness, try **Soft** or **Normal** for the
width and readjust the curve.

Halo and Halo Curve together let you change the balance between high-intensity
dwells and normal geometry. For example, try **Halo: 1.5x** with
**Halo Curve: Moderate** and enough **Halo Compression** to keep the bright
glow under control. This can make the halo around Mine Storm's bullet more
pronounced compared with the glow around normal geometry. Compare the result
with your chosen resolution, Halo Grid and Halo Spread.

If the halo becomes a bright cloud that obscures detail, try a lower Halo
Compression number. If the whole halo is too strong, lower Halo instead.

## Global Artwork Controls

Tint Strength defaults to 0, Translucent Blend to 60% and Opaque Brightness
to 50% for new or reset settings. They apply to every profile.

| Control | What you will see |
|---|---|
| **Tint Strength** | Adjusts the overlay's tint strength. Higher settings favor richer color at the expense of dynamic range. |
| **Translucent Blend** | Changes how visible the colored overlay sheet is, including areas without vectors. Lower settings give a dark-room or nighttime look that lets the vectors stand out; higher settings make the artwork more prominent. |
| **Opaque Brightness** | Changes the brightness of solid borders and printed details. These areas block vectors and glow at every tint setting. |

Tint Strength runs from -1 to +6. Its effect depends on the artwork and beam
color, so compare it in a scene with both faint lines and bright highlights.

## Diagnostic Settings

These global controls are intended for testing and troubleshooting. Keep
their defaults for normal use. Selecting or copying a profile does not
change them.

| Option | Description |
|---|---|
| **Effects Bypass** | Shows a grayscale view without bloom, halo, artwork or the Brightness curve. Beam Threshold, dwell processing and phosphor decay remain active. |
| **Reference Dwell** | Selects **46**, **72**, **Standard** or **104**. Higher values reduce stationary dwell brightness without changing expansion size. **Standard** is the default. |
| **Velocity Comp.** | Models how beam speed affects brightness on a real Vectrex: a faster beam spends less time on each part of a line, depositing less energy and producing a dimmer stroke. Select **0.3** (default), **0.4**, **0.5** or **Off**. Stationary dwell brightness is unchanged. |
| **Halo Correction** | Selects None, 50%, 75%, or 100% (default). Compensates for the pixel footprint of raster-based displays when generating halo from stationary dwells. Keep the default for an accurate look. |
| **Buffer Mode** | Selects frame presentation using detected drawing boundaries (**EOF**), display refresh (**VBL**), or both (**EOF + VBL**, default). |
| **Aspect Ratio** | Selects **Optimized**, **Stretched** or **Pixel Perfect** scaling. |

Reference Dwell, Velocity Comp. and Halo Correction are saved independently
of the selected profile. Reset Settings restores their defaults.

## Preset Settings by Resolution

The tables show the menu settings for each preset. Their columns follow the
Custom profile menu order:

- **Dwell:** Dwell Low Size / Dwell Mid Growth / Dwell High Growth
- **Brightness:** Reduced, Standard, Bright or Boost
- **Bloom:** Bloom Width / Bloom Curve
- **Halo:** Halo / Halo Curve / Halo Spread / Halo Compression / Halo Grid
- **Decay:** Inter-Frame Decay / Intra-Frame Decay
- **Vector Color:** Vectrex P4, Deluxe Blue, White, Red, Purple, Cyan or Blue

### 1080p

| Profile | Dwell | Brightness | Bloom | Halo | Decay | Vector Color |
|---|---|---|---|---|---|---|
| 80s Cruise Control | 2 / +1 / +3 | Standard | Soft / Moderate | 1.0x / Mod+ / Wide 1 / 6 / 8x8 | Short / Off | Vectrex P4 |
| 80s Overdrive | 2 / +2 / +2 | Standard | Soft / Strong- | 1.5x / Mod+ / Original / 2 / 16x16 | Medium / LUT A | Vectrex P4 |
| Neon Blue | 3 / +2 / +3 | Bright | Normal / Moderate | 0.5x / Mod+ / Original / 10 / 16x16 | Medium / LUT C | Blue |
| Red Alert | 2 / +2 / +3 | Reduced | Broad / Mild+ | 1.5x / Strong- / Wide 1 / Off / 16x16 | Long / LUT C | Red |
| Ultraviolet | 3 / +2 / +3 | Boost | Broad / Mild+ | 1.0x / Strong / Wide 1 / Off / 16x16 | Medium / LUT B | Purple |
| A Touch of CRT | 3 / +2 / +3 | Standard | Tight / Mod+ | 0.5x / Strong / Focus / 6 / 8x8 | Short / Off | Vectrex P4 |

### 720p

| Profile | Dwell | Brightness | Bloom | Halo | Decay | Vector Color |
|---|---|---|---|---|---|---|
| 80s Cruise Control | 4 / +1 / +3 | Standard | Tight / Moderate | 1.25x / Moderate / Original / 4 / 8x8 | Short / Off | Vectrex P4 |
| 80s Overdrive | 4 / +2 / +3 | Standard | Tight / Strong- | 1.5x / Strong- / Original / 2 / 8x8 | Medium / LUT A | Vectrex P4 |
| Neon Blue | 4 / +2 / +2 | Bright | Tight / Strong- | 0.25x / Mod+ / Original / 16 / 16x16 | Medium / LUT C | Blue |
| Red Alert | 3 / +4 / +3 | Reduced | Normal / Mild+ | 1.5x / Moderate / Original / Off / 16x16 | Long / LUT C | Red |
| Ultraviolet | 3 / +3 / +4 | Boost | Normal / Mild+ | 1.0x / Strong / Wide 1 / Off / 16x16 | Medium / LUT B | Purple |
| A Touch of CRT | 4 / +1 / +2 | Standard | Tight / Mild+ | 1.5x / Mild / Original / 4 / 8x8 | Short / Off | Vectrex P4 |

### 480p and 480i

| Profile | Dwell | Brightness | Bloom | Halo | Decay | Vector Color |
|---|---|---|---|---|---|---|
| 80s Cruise Control | 4 / Same / +2 | Standard | Thin / Strong- | 0.5x / Strong / Focus / 10 / 8x8 | Short / Off | Vectrex P4 |
| 80s Overdrive | 4 / Same / +3 | Standard | Tight / Mild+ | 1.0x / Mod+ / Original / 6 / 8x8 | Short / Off | Vectrex P4 |
| Neon Blue | 4 / +2 / +3 | Standard | Tight / Strong- | 0.33x / Mod+ / Focus / 24 / 16x16 | Medium / LUT A | Blue |
| Red Alert | 3 / +2 / +3 | Reduced | Tight / Strong- | 1.25x / Strong / Wide 1 / Off / 8x8 | Long / LUT C | Red |
| Ultraviolet | 2 / +3 / +2 | Boost | Tight / Mild+ | 1.0x / Strong / Wide 1 / Off / 8x8 | Medium / LUT B | Purple |
| A Touch of CRT | 4 / Same / +2 | Standard | Thin / Mod+ | 0.33x / Strong / Focus / 10 / 8x8 | Off / Off | Vectrex P4 |

### 240p

| Profile | Dwell | Brightness | Bloom | Halo | Decay | Vector Color |
|---|---|---|---|---|---|---|
| 80s Cruise Control | 3 / +2 / +2 | Standard | Thin / Mild | 1.5x / Mild / Focus / 2 / 8x8 | Off / Off | Vectrex P4 |
| 80s Overdrive | 3 / +3 / +2 | Bright | Thin / Mild+ | 1.5x / Min+ / Focus / 2 / 8x8 | Short / Off | Vectrex P4 |
| Neon Blue | 3 / +2 / +2 | Standard | Tight / Strong- | 0.33x / Mod+ / Focus / 24 / 8x8 | Medium / Off | Blue |
| Red Alert | 3 / +3 / +2 | Reduced | Thin / Strong | 0.75x / Strong / Focus / Off / 8x8 | Medium / LUT C | Red |
| Ultraviolet | 3 / +3 / +2 | Boost | Tight / Mild | 0.75x / Strong- / Focus / Off / 8x8 | Short / LUT B | Purple |
| A Touch of CRT | 3 / +2 / +1 | Standard | Thin / Minimal | 1.5x / Min+ / Focus / 2 / 8x8 | Off / Off | Vectrex P4 |
