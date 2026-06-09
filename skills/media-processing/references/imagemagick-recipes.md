# ImageMagick recipes

ImageMagick v7 uses `magick …`; v6 uses `convert …` / `mogrify …`. Examples below
use `magick` — substitute `convert` on v6. `magick` operates on one file → new file;
`mogrify` edits files **in place** (great for batches).

## Convert & compress
```bash
magick in.png out.jpg                         # format by extension
magick in.png -quality 85 out.jpg             # JPEG quality (0–100)
magick in.jpg -strip out.jpg                  # remove EXIF/metadata (smaller, private)
magick in.png -define webp:lossless=false -quality 80 out.webp
magick in.heic out.jpg                        # HEIC → JPEG (if delegates installed)
```

## Resize & crop
```bash
magick in.jpg -resize 800x600 out.jpg         # fit within 800x600 (keeps aspect)
magick in.jpg -resize 800x600^ -gravity center -extent 800x600 out.jpg  # fill + crop
magick in.jpg -resize 50% out.jpg             # half size
magick in.jpg -thumbnail 256x256 thumb.jpg    # fast thumbnail (strips metadata)
magick in.jpg -crop 400x300+10+20 +repage out.jpg   # crop WxH+X+Y
magick in.jpg -trim +repage out.jpg           # auto-trim borders
```
`>` only shrink (`-resize 1024x1024>`), `<` only enlarge, `^` fill, `!` ignore aspect.

## Rotate, flip, orient
```bash
magick in.jpg -rotate 90 out.jpg
magick in.jpg -flip out.jpg                    # vertical
magick in.jpg -flop out.jpg                    # horizontal
magick in.jpg -auto-orient out.jpg            # honor EXIF orientation
```

## Annotate & compose
```bash
magick in.jpg -gravity south -pointsize 36 -fill white \
  -annotate +0+20 'Caption' out.jpg
magick in.jpg watermark.png -gravity southeast -geometry +10+10 -composite out.jpg
magick -size 1200x300 xc:'#1e293b' -gravity center -fill white \
  -pointsize 48 -annotate 0 'Banner' banner.png        # text banner from scratch
```

## Montage / contact sheet
```bash
magick montage *.jpg -tile 4x -geometry 200x200+5+5 sheet.jpg
magick img1.png img2.png +append row.png        # side by side
magick img1.png img2.png -append column.png     # stacked
```

## Batch (mogrify edits in place — copy first!)
```bash
mkdir -p out && magick mogrify -path out -resize 1024x1024 -format jpg -quality 85 *.png
mogrify -path out -strip -auto-orient *.jpg
```

## PDF ↔ image (needs Ghostscript)
```bash
magick -density 200 doc.pdf -quality 90 page-%02d.jpg   # PDF → images (200 DPI)
magick *.jpg -auto-orient out.pdf                       # images → one PDF
magick -density 200 doc.pdf[0] cover.png                # first page only
```

## Inspect
```bash
magick identify in.jpg                          # format, dimensions, depth
magick identify -verbose in.jpg | head -40      # full metadata
magick identify -format "%wx%h\n" in.jpg        # just WxH
```

Notes:
- HEIC/PDF support depends on optional delegates (libheif, Ghostscript). If a
  conversion errors with "no decode delegate", install the delegate package.
- For audio/video, use ffmpeg (`references/ffmpeg-recipes.md`); ImageMagick is
  images-only. The bundled `img.sh` falls back to ffmpeg for basic image ops when
  ImageMagick isn't installed.
