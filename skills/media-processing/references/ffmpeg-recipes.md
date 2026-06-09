# ffmpeg recipes

`ffmpeg -i input … output`. Add `-y` to overwrite, `-loglevel error` to quiet it.
Use `-c copy` to remux without re-encoding (fast, lossless) when you're not changing
the codec; omit it to re-encode.

## Table of contents
1. [Trim & cut](#trim--cut)
2. [Concatenate](#concatenate)
3. [Transcode & compress](#transcode--compress)
4. [Extract audio / frames](#extract-audio--frames)
5. [Resize / crop / rotate](#resize--crop--rotate)
6. [GIF & thumbnails](#gif--thumbnails)
7. [Audio](#audio)
8. [Overlay, text, subtitles](#overlay-text-subtitles)
9. [Screenshots & sampling](#screenshots--sampling)

## Trim & cut
```bash
# fast cut, no re-encode (cuts at nearest keyframe)
ffmpeg -ss 00:01:00 -i in.mp4 -t 30 -c copy clip.mp4        # 30s from 1:00
ffmpeg -ss 00:01:00 -to 00:01:30 -i in.mp4 -c copy clip.mp4 # explicit end
# frame-accurate (re-encode; put -ss AFTER -i for accuracy)
ffmpeg -i in.mp4 -ss 00:01:00 -t 30 -c:v libx264 -crf 23 clip.mp4
```

## Concatenate
```bash
# same codec/params → concat demuxer (no re-encode)
printf "file '%s'\n" clip1.mp4 clip2.mp4 clip3.mp4 > list.txt
ffmpeg -f concat -safe 0 -i list.txt -c copy joined.mp4
# different sources → re-encode with the concat filter
ffmpeg -i a.mp4 -i b.mp4 -filter_complex "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" out.mp4
```

## Transcode & compress
```bash
ffmpeg -i in.mov -c:v libx264 -crf 23 -preset medium -c:a aac -b:a 192k out.mp4
ffmpeg -i in.mp4 -vf scale=-2:720 -c:v libx264 -crf 26 out_720p.mp4   # downscale + shrink
ffmpeg -i in.mp4 -c:v libx265 -crf 28 -c:a aac out_h265.mp4           # smaller (HEVC)
ffmpeg -i in.mp4 -an out_noaudio.mp4                                  # drop audio
ffmpeg -i in.webm out.mp4                                             # container/codec change
```
Lower `-crf` = higher quality, bigger file (18–28 typical). `-preset` trades speed
for size (`ultrafast`…`veryslow`).

## Extract audio / frames
```bash
ffmpeg -i in.mp4 -vn -q:a 2 out.mp3            # audio → mp3 (VBR)
ffmpeg -i in.mp4 -vn -c:a copy out.m4a         # copy audio stream as-is
ffmpeg -i in.mp4 -frames:v 1 -ss 5 frame.png   # one frame at 5s
ffmpeg -i in.mp4 -vf fps=1 frames/%04d.png     # one frame per second
ffmpeg -i in.mp4 -vf "fps=1/10" frames/%03d.jpg# one frame per 10s
```

## Resize / crop / rotate
```bash
ffmpeg -i in.mp4 -vf scale=1280:-2 out.mp4           # width 1280, height auto (even)
ffmpeg -i in.mp4 -vf "crop=640:480:0:0" out.mp4      # crop WxH at x,y (top-left)
ffmpeg -i in.mp4 -vf "transpose=1" out.mp4           # rotate 90° clockwise
ffmpeg -i in.mp4 -vf "hflip" out.mp4                 # mirror
ffmpeg -i in.mp4 -vf "scale=iw/2:ih/2" out.mp4       # half size
```

## GIF & thumbnails
```bash
# high-quality GIF via a generated palette
ffmpeg -i in.mp4 -vf "fps=12,scale=480:-1:flags=lanczos,palettegen" palette.png
ffmpeg -i in.mp4 -i palette.png -lavfi "fps=12,scale=480:-1:flags=lanczos[x];[x][1:v]paletteuse" out.gif
# quick-and-dirty
ffmpeg -ss 3 -t 4 -i in.mp4 -vf "fps=12,scale=400:-1" clip.gif
# contact-sheet thumbnail grid
ffmpeg -i in.mp4 -vf "fps=1/10,scale=160:-1,tile=5x4" -frames:v 1 sheet.png
```

## Audio
```bash
ffmpeg -i in.mp3 -af "volume=1.5" louder.mp3                 # gain
ffmpeg -i in.wav -af loudnorm out.wav                        # EBU R128 normalize
ffmpeg -i in.mp3 -ss 0 -t 30 sample.mp3                      # 30s sample
ffmpeg -i in.wav -ar 16000 -ac 1 mono16k.wav                 # 16kHz mono (ASR-ready)
ffmpeg -i in.mp4 -filter:a "atempo=1.25" faster.mp4          # speed up audio 1.25×
```

## Overlay, text, subtitles
```bash
# watermark/logo top-left with 10px margin
ffmpeg -i in.mp4 -i logo.png -filter_complex "overlay=10:10" out.mp4
# burn-in text
ffmpeg -i in.mp4 -vf "drawtext=text='Hello':x=20:y=20:fontsize=36:fontcolor=white" out.mp4
# burn-in subtitles
ffmpeg -i in.mp4 -vf "subtitles=subs.srt" out.mp4
# soft-mux subtitles (toggleable)
ffmpeg -i in.mp4 -i subs.srt -c copy -c:s mov_text out.mp4
```

## Screenshots & sampling
```bash
ffmpeg -ss 00:00:07 -i in.mp4 -frames:v 1 -q:v 2 shot.jpg    # poster frame
ffmpeg -i in.mp4 -vf "select='gt(scene,0.4)',showinfo" -vsync vfr scenes/%03d.png  # scene cuts
ffprobe -v error -show_entries format=duration -of csv=p=0 in.mp4                   # just the duration
```

Tip: H.264/H.265 require even dimensions — prefer `scale=-2:720` over `-1:720`.
