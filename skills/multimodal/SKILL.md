---
name: multimodal
requires: curl, jq
description: >
  Give the agent eyes, ears, and a voice through model APIs: analyze and
  describe images or screenshots (vision, including reading text/charts/
  receipts in photos), transcribe audio to text, summarize videos (sampled
  frames + audio track), generate images from a text prompt, and synthesize
  speech (TTS). Use whenever a task involves understanding or producing media
  rather than just converting it. Trigger phrases: "what's in this image",
  "describe this screenshot", "read this chart/receipt/sign", "transcribe",
  "voice note", "meeting recording", "what happens in this video", "watch this
  clip", "generate an image", "draw", "make a logo/picture of", "text to
  speech", "say this out loud", "narrate". For pure editing/conversion of
  existing media files (trim, resize, convert, extract frames) use the
  media-processing skill instead; the two compose.
---

# Multimodal (vision, hearing, speech, image generation)

The runtime is text-only on purpose: media goes *out* to a model API and text
comes *back* into the session. Never paste base64 media into the transcript —
run one of these scripts and let its text result be what the session remembers.

| Job | Script |
|-----|--------|
| Describe / answer questions about image(s) or screenshots | `scripts/analyze-image.sh [-p "prompt"] <path-or-url> [more ...]` |
| Audio file → transcript | `scripts/transcribe.sh <audio>` |
| Video → visual summary + transcript | `scripts/analyze-video.sh [-p "prompt"] [-n max-frames] <video>` |
| Text prompt → image file | `scripts/generate-image.sh [-s 1024x1024] [-n count] "prompt" [out.png]` |
| Text → spoken audio file | `scripts/speak.sh "text" [out.mp3]` |

Run them from the skill folder or by full path — they are self-contained and
also work outside an agent (only the env below is needed).

## Configuration (environment)

Every script resolves its endpoint the same way: a modality-specific override,
else a general value, else a default. All config comes from the environment;
API keys stay in the real environment.

| Modality | Base URL (first set wins) | API key | Model |
|----------|---------------------------|---------|-------|
| Vision | `LLM_VISION_BASE_URL` → `BASE_URL` → OpenAI | `LLM_VISION_API_KEY` → `LLM_API_KEY` | `LLM_VISION_MODEL` → `MODEL` → `gpt-5.5` |
| Audio (STT + TTS) | `LLM_AUDIO_BASE_URL` → OpenAI | `LLM_AUDIO_API_KEY` → `LLM_API_KEY` | `LLM_STT_MODEL` → `whisper-1`; `LLM_TTS_MODEL` → `tts-1`; `LLM_TTS_VOICE` → `alloy` |
| Image generation | `LLM_IMAGE_BASE_URL` → OpenAI | `LLM_IMAGE_API_KEY` → `LLM_API_KEY` | `LLM_IMAGE_MODEL` → `gpt-image-1` |

Why the asymmetry: vision rides the agent's *own* endpoint by default because
most frontier chat models (gpt-5.5, claude, gemini, grok) are natively
multimodal — the same model that runs the agent can look at images. Audio and
image generation are separate API surfaces (`/audio/*`, `/images/generations`)
that most providers don't offer, so they default to OpenAI regardless of who
runs the agent.

Provider notes:

- **Agent on a non-vision model** (e.g. a Groq llama): pin
  `LLM_VISION_BASE_URL` / `LLM_VISION_API_KEY` / `LLM_VISION_MODEL` to a vision
  provider.
- **Anthropic**: vision works on its OpenAI-compatible endpoint — images must
  be inlined base64, never remote URLs, which `analyze-image.sh` always does —
  but there are no audio or image endpoints, so STT/TTS/generation need
  `LLM_AUDIO_*` / `LLM_IMAGE_*` pointed elsewhere.
- **Groq** offers fast STT: `LLM_AUDIO_BASE_URL=https://api.groq.com/openai/v1`
  with `LLM_STT_MODEL=whisper-large-v3`.
- **NVIDIA NIM** (`nvapi-` keys): vision works on the main endpoint, but many
  NIM vision deployments (e.g. `meta/llama-3.2-90b-vision-instruct`) accept
  only one image per request — for multi-image prompts and `analyze-video.sh`
  set `LLM_VISION_MODEL=meta/llama-4-maverick-17b-128e-instruct` (or another
  multi-image model). No audio or image-generation endpoints.
- **gpt-image-1** needs a verified OpenAI org; `LLM_IMAGE_MODEL=dall-e-3` (or
  `dall-e-2` for cheap drafts) works on any key. The script handles both
  response styles (base64 and URL).

## Examples

```bash
S=skills/multimodal/scripts                       # adjust to where the skill lives

$S/analyze-image.sh photo.jpg                                  # plain description
$S/analyze-image.sh -p "Read every line of text" receipt.png   # OCR-style reading
$S/analyze-image.sh -p "Which button submits?" https://example.com/shot.png
$S/analyze-image.sh -p "What changed between these?" before.png after.png

$S/transcribe.sh meeting.m4a > transcript.txt     # redirect: see note below
$S/analyze-video.sh -p "Summarize the demo" demo.mp4
$S/generate-image.sh -s 1024x1024 "flat vector logo of a paper crane" logo.png
$S/speak.sh "Build finished, all tests green." status.mp3
```

## Limits worth knowing

- **Command-output cap**: the runtime truncates tool output (64 KB default). A
  long transcript or description survives by going to a file
  (`transcribe.sh long.mp3 > transcript.txt`), then reading it in pieces.
- **Image size**: vision endpoints reject very large payloads (~20 MB). Shrink
  huge photos first — `media-processing`'s `img.sh resize` does it in one line.
- **TTS input** caps around 4096 characters per request — split long texts.
- **Video**: `analyze-video.sh` needs ffmpeg; it samples at most `-n` frames
  (default 8) evenly across the clip so cost stays flat regardless of length,
  and a missing/failed audio track or unconfigured STT just drops the
  transcript section (noted on stderr) instead of failing the visual summary.
