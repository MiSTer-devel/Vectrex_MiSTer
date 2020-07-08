from PIL import Image
import sys

from array import *

def convertImage(name):

   name_array = name.split('_')
   print(name_array)
   print(name_array[:-1])
   out_name='_'.join(name_array[:-1])+'.ovr'
   print(out_name)

   im = Image.open(name).convert('RGBA')
   (s,s,width,height)=im.getbbox()
   print(width,height)
   count = 0

   bin_array3 = array('B')

   for y in range(height):
    for x in range(width):
        count = count+1
        pixel = im.getpixel((x,y))
        #print(pixel)
        r = pixel[0]
        g = pixel[1]
        b = pixel[2]
        a = pixel[3]
        byte1 = ((g ) &0xF0) | ((r >> 4)&0x0F)
        byte2 = (((a) ) &0xF0) | ((b >> 4)&0x0F)
        # G R
        # A B
        # A -- F to be opaque
        #byte1 = 0x0F
        #byte2 = 0x00
        bin_array3.append(byte1)
        bin_array3.append(byte2)
   newFile = open(out_name, "wb")
   newFile.write(bin_array3)

if __name__ == "__main__":
  #print(sys.argv[1])
  convertImage(sys.argv[1])
