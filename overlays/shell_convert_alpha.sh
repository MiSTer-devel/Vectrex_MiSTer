SAVEIFS=$IFS
IFS=$(echo -en "\n\b")

for x in `ls *_Small.png` 
do
	echo "Converting $x..."
        python convert_image_alpha.py $x
done

rm overlays.zip
zip -r overlays.zip *.ovr
rm *.ovr
