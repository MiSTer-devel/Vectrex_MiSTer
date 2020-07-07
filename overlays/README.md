
# Overlays for Vectrex

The overlays should be PNGs with an Alpha channel  540px x 720 px.  The shell_convert_alpha.sh script will run the python script for each png with the name *_Small.png in this directory. It will call the python script, and then zip the resulting .ovr files.  The ovr files are simply a raw uncompressed binary file with RGBA as 4 bit values (2 colors packed into each 8 bit value). 


##Overlay Sources

*https://github.com/libretro/overlay-borders
They have an MIT license.

*https://github.com/thebezelproject/bezelproject-GCEVectrex/tree/master/retroarch/overlay/GameBezels/GCEVectrex

*https://github.com/raphkoster/vectrex-overlays



