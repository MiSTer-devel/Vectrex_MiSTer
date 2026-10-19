# Vectrex Overlay Tools

Create Vectrex `.art` overlays on a Windows, Linux or macOS computer, then
copy the results to MiSTer. These tools also extract PNGs from existing ART
files. They do not need to run on MiSTer.

For ready-made artwork, use the separate `overlays.zip` download supplied
with the core.
Standard artwork is at the archive root; both rotated versions are in `Tate`.
Extract the archive to `/media/fat/games/Vectrex/Overlays/` for manual loading.
The included `CREDITS.md` lists the artwork sources.

## Setup

Download the complete `Overlay Tools` folder, including `images`. Keep all
files together and open a terminal in that folder.

Install **Python 3.10 or later** and its dependencies:

```text
python -m pip install -r requirements.txt
```

Use `python3` if that is your system's Python command. A Python virtual
environment is recommended; activate it before running these commands.

For palette reduction, install **Node.js 20.9 or later**, including npm, then:

```text
npm install --no-package-lock
```

This installs the required Sharp version in the tools folder. If you only
extract existing ART files, you can skip the Node.js setup. For a separate
dependency folder or a Node executable outside PATH, see
[Advanced setup](readme-technical.md#advanced-setup).

## Prepare the PNG

Start with an **846 x 1080 RGBA PNG**. The original Vectrex overlay was a
printed sheet: colored material tinted the beam, while solid printing
provided borders, logos and instructions. Set alpha accordingly:

| Region | Alpha |
| --- | ---: |
| Solid borders, lettering and decorations | 255 |
| Translucent colored filters | 51 |
| Clear windows and margins | 0 |

Only alpha 255 completely blocks the beam. For a deliberately different
translucent alpha, use `--preserve-alpha` when building. Keep your source PNG;
an extracted ART image includes any palette reduction already applied.

## Build artwork

Paths are relative to the terminal's current directory. Quote paths with
spaces. These examples put results in a separate output folder:

```text
python build_art.py build "../My Overlay.png" -o "../Overlay Output"
```

This produces `My Overlay.art`, `My Overlay_90CW.art` and
`My Overlay_90CCW.art`. Each contains 1080p, 720p, 480p and 240p artwork;
480i uses the 480p plane. The core selects the resolution automatically.

The default limit is 64 RGBA palette entries per resolution. For more colors
or reviewed alpha values, put the global options before `build`:

```text
python build_art.py --max-colors 256 --preserve-alpha build "../My Overlay.png" -o "../Overlay Output"
```

To separate standard and rotated packages, provide two output folders:

```text
python build_art.py build "../My Overlay.png" -o "../Overlay Output" -o "../Overlay Output/Tate"
```

`build-all` converts every PNG directly in an input folder. Use `pack` instead
of `build` for separately authored full-screen planes, such as a bezel with
instructions beside the playfield. See [packing prepared planes](readme-technical.md#pack-separately-prepared-resolution-images).

## Extract artwork

```text
python build_art.py extract "../Mine_Storm.art" -o "../Extracted Artwork"
```

This extracts the normal 1080p overlay sheet. Use `--resolution 720p` to select
another plane, `--all-resolutions` for all four, or `--full-plane` to retain
the surrounding raster. Rotated filename suffixes select the matching crop;
use `--orientation cw` or `--orientation ccw` for renamed rotated packages.

## Load the result on MiSTer

Copy an ART file to the Vectrex games directory and choose **Load Overlay**.
For automatic loading, put it beside the game ROM and give the artwork the
same basename, for example `Mine_Storm.vec` and `Mine_Storm.art`. Use the
orientation that matches your display. Rename a copy of the artwork when
needed, keeping your original packages.

Loading artwork selects **Overlay: On**, **Framing: Overlay** and
**View Area: Standard**. You can adjust these settings afterward.

```text
python build_art.py --help
python build_art.py build --help
python build_art.py extract --help
```

See the [technical reference](readme-technical.md) for all options, alpha
handling, resizing, palette reduction and plane geometry.
