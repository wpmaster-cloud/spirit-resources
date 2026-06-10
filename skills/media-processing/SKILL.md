---
name: media-processing
requires: ffmpeg
description: >
  Process audio, video, and images from the command line with ffmpeg and
  ImageMagick — trim/cut/concat clips, convert formats, extract audio or frames,
  resize/crop/compress, make thumbnails and GIFs, adjust volume, take screenshots,
  and inspect media metadata. Use whenever a task involves an existing audio/video/
  image file that needs transforming or converting (mp4, mov, mp3, wav, png, jpg,
  webp, gif, …). This is the editing/conversion counterpart to the multimodal
  skill (image analysis & generation, transcription, speech synthesis). Trigger
  phrases: "convert this video", "trim the clip", "extract audio", "make a gif",
  "resize the image", "compress this", "thumbnail", "screenshot the video at",
  "merge these clips", "change the format", "what codec is this".
---

# Media processing (ffmpeg + ImageMagick)

Command-line audio/video/image editing. Two universal tools do nearly everything;
the bundled scripts cover the two awkward bits (inspecting a file, and
resize/convert with a graceful fallback). The recipe references carry the rest.

| Job | Tool |
|-----|------|
| Audio & video: trim, concat, transcode, extract audio/frames, GIF, volume | **ffmpeg** → `references/ffmpeg-recipes.md` |
| Images: resize, convert, crop, compress, thumbnail, annotate, montage | **ImageMagick** → `references/imagemagick-recipes.md` |
| Inspect any media file (duration, codecs, resolution, streams) | **`media_info.sh`** (ffprobe) |
| Quick image convert/resize/thumbnail with a fallback | **`img.sh`** |

```
skills/media-processing/
├── SKILL.md
├── scripts/
│   ├── media_info.sh    # ffprobe summary of any audio/video/image file
│   └── img.sh           # convert | resize | thumb  (ImageMagick, else ffmpeg)
└── references/
    ├── ffmpeg-recipes.md
    └── imagemagick-recipes.md
```

`run_command` runs from the **workspace root**; outputs land wherever you point
them (e.g. `media/` or `temp/`).

## Inspect first

```bash
bash skills/media-processing/scripts/media_info.sh input.mp4
bash skills/media-processing/scripts/media_info.sh input.mp4 --raw   # full JSON
```
Knowing the duration, codecs, resolution, and stream layout up front saves you from
guessing flags. (Needs ffmpeg; install line printed if missing.)

## Common one-liners

```bash
# trim 30s starting at 00:01:00 (fast, no re-encode)
ffmpeg -ss 00:01:00 -i in.mp4 -t 30 -c copy clip.mp4

# extract audio as mp3
ffmpeg -i in.mp4 -vn -q:a 2 out.mp3

# transcode / shrink to 720p H.264
ffmpeg -i in.mov -vf scale=-2:720 -c:v libx264 -crf 23 -c:a aac out.mp4

# grab a frame at 5s
ffmpeg -ss 5 -i in.mp4 -frames:v 1 frame.png

# make a GIF (palette method, good quality)
ffmpeg -i in.mp4 -vf "fps=12,scale=480:-1:flags=lanczos" out.gif

# images via the wrapper (ImageMagick or ffmpeg fallback)
bash skills/media-processing/scripts/img.sh convert photo.png photo.jpg
bash skills/media-processing/scripts/img.sh resize  photo.png 1024x1024 small.png
bash skills/media-processing/scripts/img.sh thumb   photo.png thumb.png 256
```
Many more (concat, overlay/watermark, subtitles, normalize audio, crop, batch
convert, strip metadata, PDF↔image) are in the two reference files — read the
relevant one before a non-trivial job.

## Installing the tools

- **ffmpeg** (includes `ffprobe`): `apt-get install -y ffmpeg` (Debian/Ubuntu) · `apk add ffmpeg` (Alpine) · `brew install ffmpeg` (macOS)
- **ImageMagick** (`magick`/`convert`): `apt-get install -y imagemagick` · `apk add imagemagick` · `brew install imagemagick`

In the deployed container neither tool is baked in, and the agent user can't
`apk add` (non-root) — bake them into the image (uncomment the extras
line in `ops/Dockerfile`) when a containerized agent needs media work.

`img.sh` falls back to ffmpeg for convert/resize/thumbnail when ImageMagick isn't
installed, so simple image work still succeeds with ffmpeg alone.

## Gotchas (important in this runtime)

- **`run_command` has a wall-clock timeout** (`COMMAND_TIMEOUT_SEC`, default 120 s).
  Long encodes can exceed it — keep jobs short (use `-ss`/`-t` to work on a segment),
  raise the timeout for the run, or run the encode in the background (`nohup … &`)
  and poll the output file. ffmpeg writes to a file regardless, so a timed-out
  command may still have produced partial output.
- **Don't print binaries** — tools write to files; scripts emit only a short summary,
  not the media bytes. Captured output is capped, so never `cat` a media file.
- **`-c copy` vs re-encode** — copying streams (`-c copy`) is near-instant but only
  works when you're not changing the codec/filtering; cutting on a keyframe boundary
  matters. Omit it to re-encode precisely.
- **`-y`** overwrites the output without prompting (the scripts use it); drop it if
  you want ffmpeg to refuse to clobber.
- **Even dimensions** — H.264/H.265 need even width/height; use `scale=-2:720`
  (the `-2` keeps aspect *and* rounds to an even number) rather than `-1`.
- **Quality knobs** — video: lower `-crf` = better/bigger (18–28 typical, 23
  default). Audio: `-q:a 2` (VBR mp3) or `-b:a 192k`.
