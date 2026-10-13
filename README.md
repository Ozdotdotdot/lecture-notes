# Lecture Notes

Mac app for turning an Urdu/Hindi YouTube lecture into English study notes, saved as a PDF.

Paste a link and click **Make Notes**. The engine then:
1. downloads the audio (yt-dlp, which updates itself daily through Homebrew)
2. transcribes it on the Mac's GPU (mlx-whisper, `whisper-large-v3-turbo`, language `ur`)
3. writes English notes with Muse Spark via `opencode run --standalone` (free `muse-spark-1.3-contributor-free`, falling back to the paid `muse-spark-1.3`)
4. renders a PDF (WeasyPrint, with Arabic/Urdu in Geeza Pro / Noto Nastaliq) to `~/Documents/Lecture Notes/`

## Layout
- `app/main.swift`: the SwiftUI app (queue, progress, notifications). It runs the engine once per link.
- `app/make_icon.swift`: draws the app icon
- `engine/engine.py`: the pipeline. It prints one JSON progress object per line.
- `build.sh`: builds `dist/Lecture Notes.app` (needs the Xcode command line tools, on Apple Silicon)
- `install.sh`: installs the Homebrew tools, the engine venv in `~/Library/Application Support/Lecture Notes/engine`, the speech model, and the app in `/Applications`

## Install on a new Mac
Requires Homebrew. Copy this folder plus `dist/` over, run `./install.sh`, then `opencode auth login` if it isn't already signed in.
