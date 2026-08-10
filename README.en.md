# process-videos

[中文](README.md) | [English](README.en.md)

> Preprocess tutorial videos into AI-friendly assets (subtitles + keyframes), then use an AI assistant to produce follow-along coding notes quickly.

**Best for**: learning from video courses (especially programming). The video is long and slow; you want a Markdown walkthrough you can code from—without scrubbing the timeline over and over.

> 📌 **This repo evolved from a video preprocessor into a “preprocess + learning collaboration loop”**: besides turning videos into AI-readable assets, it also documents a workflow of “notes first → you implement → I review → revise the notes”.
>
> - Lower layer (video → assets + walkthrough docs): [SKILL.md](SKILL.md) (`video-to-doc`)
> - Upper layer (course follow-along loop): [course-follow-along-skill.md](course-follow-along-skill.md)

## What problem it solves

Letting an AI “watch” raw video is slow and unreliable: large `.mp4` files, speech-to-text that can take tens of minutes, and frame analysis that burns tokens.

This project splits the work into **two steps**:

1. **One-time preprocess** (`preprocess-videos.sh`): extract audio, transcribe subtitles, capture keyframes; cache everything under `video-notes-cache/` next to the videos
2. **On-demand consumption** (Cursor Skills): the AI reads cached subtitles and frames and can produce docs in minutes

Result: preprocess a batch once (often 1–3 hours as a background job), then regenerate any style of notes in minutes.

---

## Features

- **Idempotent cache**: fingerprint by file size + mtime; unchanged videos are skipped
- **Failure isolation**: one failed video does not stop the rest; `--retry-failed` re-runs failures
- **Default model `large-v3-turbo`**: good Chinese accuracy and speed on Apple Silicon (whisper.cpp + Metal)
- **Cursor Skills**: copy [SKILL.md](SKILL.md) into `~/.cursor/skills/video-to-doc/` so the AI follows a consistent doc format
- **Non-invasive**: subtitles stay under `video-notes-cache/`; they do not clutter the video folder

---

## Prerequisites

### macOS

```bash
brew install ffmpeg whisper-cpp
```

### Linux

```bash
# ffmpeg
sudo apt install ffmpeg        # Debian/Ubuntu
sudo dnf install ffmpeg        # Fedora

# Build whisper.cpp from source: https://github.com/ggml-org/whisper.cpp
# Put the binary on PATH as whisper-cli
```

On **first run**, if the model is missing, the script downloads `ggml-large-v3-turbo.bin` (~1.6GB) into `<script-dir>/whisper-models/` (e.g. `~/Tools/process-videos/whisper-models/`, gitignored). It usually beats the old `medium` default on both quality and speed for Chinese.

Or download manually:

```bash
mkdir -p ~/Tools/process-videos/whisper-models
curl -L -C - \
  -o ~/Tools/process-videos/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

---

## Quick start

```bash
# 1. Clone anywhere
git clone https://github.com/tyler4400/process-videos.git ~/Tools/process-videos

# 2a. Preprocess a chapter directory (all videos in that folder)
~/Tools/process-videos/preprocess-videos.sh "/path/to/chapter-16"

# 2b. Or a single video (cache still goes under that video's directory)
~/Tools/process-videos/preprocess-videos.sh "/path/to/chapter-16/16-5-animation.mp4"

# 3. Check status (directory or single file)
~/Tools/process-videos/preprocess-videos.sh "/path/to/chapter-16" --status

# 4. After preprocess, ask Cursor to write notes (see prompt examples below)
```

Default model is `large-v3-turbo`. Override temporarily:

```bash
~/Tools/process-videos/preprocess-videos.sh "/path/to/videos" --model medium
```

### Output layout

```
/path/to/chapter-16/
├── 16-1 xxx.mp4
├── 16-2 xxx.mp4
├── ...
└── video-notes-cache/          ← preprocess artifacts
    ├── manifest.tsv            ← cache index
    ├── 16-1 xxx/
    │   ├── transcript.srt      ← timed subtitles
    │   ├── transcript.txt      ← plain text
    │   ├── frames/
    │   │   ├── frame_001.jpg   ← one frame every 10s by default
    │   │   └── ...
    │   ├── .fingerprint
    │   └── whisper.log
    ├── 16-2 xxx/
    │   └── ...
```

---

## Command reference

Accepts a **directory** (all videos in that folder) or a **single video file**. Cache always lives in `video-notes-cache/` under the video’s parent directory.

```bash
preprocess-videos.sh <dir|video>                     preprocess
preprocess-videos.sh <dir|video> --model small       choose whisper model
preprocess-videos.sh <dir|video> --frame-interval 5  keyframe interval seconds (default 10)
preprocess-videos.sh <dir|video> --status            show cache status
preprocess-videos.sh <dir|video> --clean             delete cache (interactive confirm)
preprocess-videos.sh <dir|video> --retry-failed      retry failed entries
preprocess-videos.sh --version                       show version
preprocess-videos.sh --help                          show help
```

### Directory vs single video

| Command | Directory | Single video |
|---|---|---|
| `process` (default) | Process all videos; skip cached | Process only that file |
| `--status` | List all manifest rows | Show that video only |
| `--clean` | Remove whole `video-notes-cache/` | Remove that video’s subdirectory |
| `--retry-failed` | Retry all failed rows | Retry that video if failed |

> 💡 Mixing modes is safe: preprocess `A/16-1.mp4` alone, then run on directory `A`—`16-1.mp4` is skipped automatically.

### Whisper model choices

| Model | Size | Chinese quality | Speed (vs realtime) |
|---|---|---|---|
| tiny | 75MB | Poor | ~10-20x |
| base | 142MB | Fair | ~7-10x |
| small | 466MB | OK | ~3-5x |
| medium | 1.4GB | Good | ~1-2x |
| **large-v3-turbo (default)** | **1.6GB** | **Very good** | **Often faster than medium** |
| large-v3 | 2.9GB | Best | ~0.5x |

> Speeds are rough Apple Silicon (whisper.cpp Metal) estimates; “1x” means transcription time ≈ audio duration. `large-v3-turbo` is a distilled large-v3: near-large quality, better default size/speed.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `WHISPER_MODELS_DIR` | `<script-dir>/whisper-models` | Model directory |
| `FRAME_INTERVAL` | `10` | Keyframe interval (seconds); override with `--frame-interval N` |
| `VIDEO_EXTENSIONS` | `mp4 mkv mov avi webm flv` | Recognized extensions |

> Priority: **CLI > env > defaults**

```bash
# One-shot
FRAME_INTERVAL=5 ~/Tools/process-videos/preprocess-videos.sh /path/to/videos

# Current shell
export FRAME_INTERVAL=5
~/Tools/process-videos/preprocess-videos.sh /path/to/videos

# Permanent
echo 'export FRAME_INTERVAL=5' >> ~/.zshrc
source ~/.zshrc
```

---

## Using with an AI assistant

Two layered skills:

| Skill | File | Role |
|---|---|---|
| **video-to-doc** (lower) | [SKILL.md](SKILL.md) | Video → subtitles/frames → walkthrough doc |
| **course-follow-along** (upper) | [course-follow-along-skill.md](course-follow-along-skill.md) | Learning loop: notes first → you implement → review → revise notes |

The upper skill references the lower one—**point at the upper skill** and it pulls the lower layer in.

### Option 1: Manual path reference (recommended, zero config across machines)

Clone anywhere; paste the skill path in chat:

```
Follow the course videos using <clone-path>/course-follow-along-skill.md.
```

### Option 2: Install into Cursor auto-discovery (optional)

```bash
mkdir -p ~/.cursor/skills/video-to-doc
cp <clone-path>/SKILL.md ~/.cursor/skills/video-to-doc/SKILL.md

mkdir -p ~/.cursor/skills/course-follow-along
cp <clone-path>/course-follow-along-skill.md ~/.cursor/skills/course-follow-along/SKILL.md
```

> ⚠️ Do not put these under `~/.cursor/skills-cursor/` (reserved for built-in Cursor skills).

**Other agents** (Claude Code, Windsurf, etc.): paste skill content into system / project instructions.

---

## Prompt examples

### 1. Batch-preprocess a chapter

```
Please run the preprocess script on this directory:
/Users/me/videos/chapter-16-animation

  Command: ~/Tools/process-videos/preprocess-videos.sh "<path above>"

Report --status when done.
```

Expect a long background job (often 1–3 hours depending on total duration).

### 1b. Single video only

```
Only preprocess this one video:
/Users/me/videos/chapter-16-animation/16-5-transition.mp4
```

Cache lands under `video-notes-cache/16-5-transition/`. Later directory runs skip this file.

### 2. One walkthrough doc from one video

```
Write a follow-along note for this video (preprocess already done):
/Users/me/videos/chapter-16-animation/16-5-transition.mp4

Requirements:
- Steps in video order
- Timestamp each step as ⏱ MM:SS - MM:SS
- Put the doc under docs/video-notes/
```

### 3. Merge several videos into one “final-state” guide

```
Merge these 4 videos into one follow-along doc, reorganized by feature,
final state only (no “write wrong then fix” steps):
- 16-5 xxx.mp4
- 16-6 xxx.mp4
- 16-7 xxx.mp4
- 16-8 xxx.mp4

Save under docs/video-notes/ with a collection-style filename.
```

### 4. Quick summary only

```
What is this video roughly about? No code needed:
/Users/me/videos/chapter-16-animation/16-1-intro.mp4
```

### 5. Check preprocess status

```
How far along is preprocess for:
/Users/me/videos/chapter-16-animation
```

Or for one file:

```
Is this video done?
/Users/me/videos/chapter-16-animation/16-5.mp4
```

---

## How it works

```
  ┌──────────────┐       ┌───────────────────────┐      ┌──────────────┐
  │  video files │──────▶│ preprocess-videos.sh  │─────▶│  video-notes-│
  │  (*.mp4)     │       │  (ffmpeg + whisper)   │      │  cache/      │
  └──────────────┘       └───────────────────────┘      └──────┬───────┘
                                                                │
                                                                │ (SKILL guides AI reads)
                                                                ▼
                                                       ┌──────────────────┐
                                                       │  Markdown docs   │
                                                       │  (docs/video-    │
                                                       │   notes/xxx.md)  │
                                                       └──────────────────┘
```

**Key idea**: cache is AI-cheap (SRT text + JPG frames), so rewriting docs later is fast.

---

## FAQ

### Slow model download?

Download manually into `whisper-models/`:

```bash
mkdir -p ~/Tools/process-videos/whisper-models
curl -L -C - \
  -o ~/Tools/process-videos/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

`-C -` resumes interrupted downloads.

### Typos in Chinese transcripts?

`large-v3-turbo` is usually clearly better than `medium` for spoken Chinese, but typos still happen. They rarely block AI understanding (context fills gaps). For max quality try `--model large-v3` (slower, ~2.9GB).

### Recursive subdirectories?

Not yet—only one level (`-maxdepth 1`). Run once per chapter folder. PRs welcome.

### A video failed?

```bash
cat "/path/to/video-notes-cache/failed-video/whisper.log"
```

Common causes: disk full, corrupt video, damaged model file, missing `whisper-cli` (`brew install whisper-cpp` on macOS). Then:

```bash
preprocess-videos.sh "<same path>" --retry-failed
```

### Re-run one video from scratch?

```bash
rm -rf "/path/to/video-notes-cache/that-video-name"
```

The next run reprocesses it.

---

## License

MIT — see [LICENSE](LICENSE).

## Contributing

PRs welcome, especially:

- Windows / Linux testing and compatibility
- Recursive directory support
- Direct YouTube (or similar) URL ingest
- Better multilingual defaults (Chinese-first today)
