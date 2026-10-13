#!/bin/bash
# Installs Lecture Notes on this Mac: tools via Homebrew, the engine in
# ~/Library/Application Support/Lecture Notes/engine, and the app in /Applications.
# Run from the folder that contains engine/ and dist/ (made by build.sh). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
SUPPORT="$HOME/Library/Application Support/Lecture Notes"
ENGINE="$SUPPORT/engine"

if [ ! -x /opt/homebrew/bin/brew ]; then
  echo "Homebrew is required. Install it first: https://brew.sh" >&2
  exit 1
fi
export PATH="/opt/homebrew/bin:$PATH" HOMEBREW_NO_ENV_HINTS=1

echo "==> Tools"
brew install -q ffmpeg yt-dlp deno pango uv opencode

echo "==> Engine"
mkdir -p "$ENGINE" "$HOME/Documents/Lecture Notes"
cp engine/engine.py "$ENGINE/engine.py"
[ -d "$ENGINE/.venv" ] || uv venv -q -p 3.12 "$ENGINE/.venv"
uv pip install -q -p "$ENGINE/.venv" mlx-whisper weasyprint markdown

echo "==> Speech model (one-time ~1.6 GB download)"
"$ENGINE/.venv/bin/python" -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/whisper-large-v3-turbo')" >/dev/null

echo "==> App"
rm -rf "/Applications/Lecture Notes.app"
cp -R "dist/Lecture Notes.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Lecture Notes.app" 2>/dev/null || true

echo "==> Checks"
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib "$ENGINE/.venv/bin/python" -c "import mlx_whisper, weasyprint, markdown" && echo "engine ok"
if opencode auth list 2>/dev/null | grep -qi "opencode"; then
  echo "opencode login ok"
else
  echo "!! Not signed in to OpenCode yet. Run:  opencode auth login   (choose OpenCode Zen)"
fi
echo "Done. Open 'Lecture Notes' from Applications (drag it to the Dock to keep it handy)."
