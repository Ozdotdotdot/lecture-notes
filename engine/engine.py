#!/usr/bin/env python3
"""Lecture Notes engine: YouTube link -> Urdu/Hindi transcript -> English study notes PDF.

Prints one JSON object per line on stdout so the app can show progress:
  {"stage": "...", "progress": 0.0-1.0, "title": "...", "message": "..."}
and finishes with {"stage": "done", "pdf": "..."} or {"stage": "error", "message": "..."}.

Usage: engine.py <youtube-url>
       engine.py --render <notes.md> <out.pdf> [title] [url]   (re-render a PDF only)
"""
import datetime as dt
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/Lecture Notes"
WORK = SUPPORT / "work"
OUTPUT = HOME / "Documents/Lecture Notes"
BREW = "/opt/homebrew/bin"
os.environ["PATH"] = f"{BREW}:{os.environ.get('PATH', '')}"
os.environ.setdefault("DYLD_FALLBACK_LIBRARY_PATH", "/opt/homebrew/lib")

WHISPER_MODEL = os.environ.get("LN_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
NOTES_MODELS = ["opencode/muse-spark-1.3-contributor-free", "opencode/muse-spark-1.3"]


def emit(stage, progress=None, **kw):
    msg = {"stage": stage, **kw}
    if progress is not None:
        msg["progress"] = round(max(0.0, min(1.0, progress)), 3)
    print(json.dumps(msg, ensure_ascii=False), flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ---------------------------------------------------------------- steps

def update_downloader():
    """YouTube changes often and breaks yt-dlp; upgrade it at most once a day."""
    stamp = SUPPORT / ".yt-dlp-updated"
    if stamp.exists() and time.time() - stamp.stat().st_mtime < 86400:
        return
    env = {**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "0", "HOMEBREW_NO_ENV_HINTS": "1"}
    r = run([f"{BREW}/brew", "upgrade", "-q", "yt-dlp"], env=env, timeout=300)
    if r.returncode == 0 or "already installed" in r.stderr:
        stamp.touch()


def video_info(url):
    r = run(["yt-dlp", "--no-warnings", "--no-playlist", "-J", url], timeout=120)
    if r.returncode != 0:
        raise RuntimeError("Couldn't open that YouTube link. Check that it's a video link and try again.\n\n" + r.stderr[-500:])
    d = json.loads(r.stdout)
    return {"id": d["id"], "title": d.get("title") or d["id"], "channel": d.get("channel") or d.get("uploader") or "",
            "duration": d.get("duration") or 0, "url": d.get("webpage_url") or url,
            "date": d.get("upload_date") or ""}


def download_audio(info, job):
    out = job / "audio.m4a"
    if out.exists():
        return out
    proc = subprocess.Popen(["yt-dlp", "--no-warnings", "--no-playlist", "--newline", "-f", "bestaudio",
                             "-x", "--audio-format", "m4a", "-o", str(job / "audio.%(ext)s"), info["url"]],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    tail = []
    for line in proc.stdout:
        tail = (tail + [line])[-20:]
        m = re.search(r"\[download\]\s+([\d.]+)%", line)
        if m:
            emit("downloading", float(m.group(1)) / 100)
    if proc.wait() != 0 or not out.exists():
        raise RuntimeError("Downloading the video failed.\n\n" + "".join(tail)[-500:])
    return out


def transcribe(audio, info, job):
    out = job / "transcript.json"
    if out.exists():
        return json.loads(out.read_text())
    import tqdm as tqdm_mod
    import mlx_whisper

    class Progress(tqdm_mod.tqdm):  # mlx-whisper reports progress through tqdm
        def __init__(self, *a, **k):
            k["disable"] = True
            super().__init__(*a, **k)
            self._done, self._total = 0, k.get("total") or 1

        def update(self, n=1):
            self._done += n
            emit("listening", self._done / self._total)

    real = tqdm_mod.tqdm
    tqdm_mod.tqdm = Progress
    try:
        emit("listening", 0.0)
        r = mlx_whisper.transcribe(str(audio), path_or_hf_repo=WHISPER_MODEL, language="ur",
                                   condition_on_previous_text=False, verbose=False)
    finally:
        tqdm_mod.tqdm = real
    segs = [{"start": round(s["start"], 1), "end": round(s["end"], 1), "text": s["text"].strip()}
            for s in r["segments"] if s["text"].strip()]
    if not segs:
        raise RuntimeError("No speech was found in this video.")
    out.write_text(json.dumps(segs, ensure_ascii=False))
    return segs


def transcript_text(segs):
    """Group segments into roughly one-minute lines, each starting with [mm:ss]."""
    lines, cur, start = [], [], None
    for s in segs:
        start = s["start"] if start is None else start
        cur.append(s["text"])
        if s["end"] - start >= 60:
            lines.append(f"[{stamp(start)}] " + " ".join(cur))
            cur, start = [], None
    if cur:
        lines.append(f"[{stamp(start)}] " + " ".join(cur))
    return "\n".join(lines)


def stamp(sec):
    sec = int(sec)
    return f"{sec // 3600}:{sec % 3600 // 60:02d}:{sec % 60:02d}" if sec >= 3600 else f"{sec // 60:02d}:{sec % 60:02d}"


PROMPT = """The attached file is an automatic transcript (speech-to-text, so expect mis-heard words, especially Arabic terms) of a lecture in Urdu/Hindi.
Video title: "{title}"{channel}
Each line starts with a [mm:ss] timestamp.

Write clear English study notes for a student who attended the lecture. Output Markdown only, with no preamble and nothing after the notes:

# <lecture title in English>
**Speaker:** ... · **Length:** {length}

## Summary
3-5 sentences.

## Key points
Bulleted, in lecture order, each starting with its [mm:ss] timestamp in bold. Explain the ideas, don't just list them.

## Names, terms and verses
Arabic/Urdu terms and any Quran verses or hadith mentioned: the original in Arabic script where you can infer it, transliteration, English meaning, timestamp. Fix obvious transcription errors in religious terms. Only give verse/hadith references you are confident about.

## Practical takeaways
Anything the speaker asks listeners to do, practise or reflect on.

Do not use any tools; answer directly."""


def write_notes(info, segs, job):
    out = job / "notes.md"
    if out.exists():
        return out.read_text()
    (job / "transcript.txt").write_text(transcript_text(segs))
    length = f"~{round(info['duration'] / 60)} minutes" if info["duration"] else "..."
    prompt = PROMPT.format(title=info["title"], length=length,
                           channel=f"\nChannel: {info['channel']}" if info["channel"] else "")
    expected = 90.0
    errors = []
    for model in NOTES_MODELS:
        done = threading.Event()
        t0 = time.time()

        def tick():  # the model gives no progress signal, so estimate from a typical run time
            while not done.wait(2):
                emit("writing", min(0.95, (time.time() - t0) / expected))

        threading.Thread(target=tick, daemon=True).start()
        try:
            # opencode resolves -f against $PWD, not the process cwd, so pass an absolute path.
            r = run(["opencode", "run", "--standalone", "-m", model, "-f", str(job / "transcript.txt"), prompt],
                    cwd=job, env={**os.environ, "PWD": str(job)}, timeout=900)
        except subprocess.TimeoutExpired:
            errors.append(f"{model}: timed out")
            continue
        finally:
            done.set()
        text = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout)
        text = "\n".join(l for l in text.splitlines() if not l.startswith("> ")).strip()
        start = text.find("# ")
        if r.returncode == 0 and start != -1 and "## " in text:
            notes = text[start:]
            out.write_text(notes)
            return notes
        errors.append(f"{model}: exit {r.returncode} {(r.stderr or text)[-300:]}")
    raise RuntimeError("Writing the notes failed.\n\n" + "\n".join(errors))


# ---------------------------------------------------------------- PDF

ARABIC_RUN = re.compile(r"([؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]"
                        r"[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿\sً-ٰٟـ،؛؟.:,\-–()]*"
                        r"[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿ً-ٰٟ])")

CSS = """
@page { size: Letter; margin: 0.8in 0.85in;
  @bottom-center { content: counter(page) " / " counter(pages); font: 9pt "Helvetica Neue"; color: #888; } }
body { font: 11pt/1.55 "Helvetica Neue", Helvetica, sans-serif; color: #1d1d1f; }
h1 { font-size: 21pt; line-height: 1.2; margin: 0 0 4pt; color: #0b3d2e; }
h2 { font-size: 14pt; margin: 20pt 0 6pt; padding-bottom: 3pt; border-bottom: 1.5pt solid #c9a227; color: #0b3d2e; }
p, li { orphans: 2; widows: 2; }
li { margin: 0 0 5pt; }
ul { padding-left: 16pt; }
strong { color: #0b3d2e; }
.meta { color: #666; font-size: 9.5pt; margin-bottom: 12pt; }
.meta a { color: #666; }
.ar { font-family: "Geeza Pro", "SF Arabic", serif; font-size: 13pt; direction: rtl; unicode-bidi: isolate; }
.ur { font-family: "Noto Nastaliq Urdu", "Geeza Pro", serif; }
.foot { margin-top: 24pt; font-size: 8.5pt; color: #999; border-top: 0.5pt solid #ddd; padding-top: 6pt; }
"""


def render_pdf(notes_md, pdf_path, title="", url=""):
    import markdown
    from weasyprint import HTML

    body = markdown.markdown(notes_md, extensions=["sane_lists"])
    body = ARABIC_RUN.sub(lambda m: f'<span class="ar" dir="rtl">{m.group(1)}</span>', body)
    first_h1_end = body.find("</h1>")
    meta = f'<div class="meta">Source: <a href="{html.escape(url)}">{html.escape(title or url)}</a> · Notes made {dt.date.today():%B %-d, %Y}</div>' if url else ""
    if first_h1_end != -1:
        body = body[:first_h1_end + 5] + meta + body[first_h1_end + 5:]
    foot = ('<div class="foot">Made automatically from the video\'s audio by speech-to-text and AI. '
            'Please double-check Quran and hadith references.</div>')
    doc = f'<html><head><meta charset="utf-8"><style>{CSS}</style></head><body>{body}{foot}</body></html>'
    HTML(string=doc).write_pdf(pdf_path)


def safe_name(title):
    name = re.sub(r'[/:\\?*"<>|\n\r\t]+', " ", title)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return (name[:120] or "Lecture").rstrip()


# ---------------------------------------------------------------- main

def main(url):
    SUPPORT.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    emit("preparing", 0.0)
    try:
        update_downloader()
    except Exception:
        pass  # an old yt-dlp might still work; the download step reports real failures
    info = video_info(url)
    emit("preparing", 1.0, title=info["title"], duration=info["duration"])
    job = WORK / info["id"]
    job.mkdir(parents=True, exist_ok=True)
    (job / "info.json").write_text(json.dumps(info, ensure_ascii=False))

    audio = download_audio(info, job)
    emit("downloading", 1.0)
    segs = transcribe(audio, info, job)
    emit("listening", 1.0)
    notes = write_notes(info, segs, job)
    emit("writing", 1.0)

    emit("saving", 0.5)
    # Name the PDF after the notes' English heading; YouTube titles are cluttered.
    heading = re.match(r"#\s+(.+)", notes)
    base = safe_name(heading.group(1).strip("*_ ") if heading else info["title"])
    pdf, n = OUTPUT / f"{base}.pdf", 2
    while pdf.exists():
        pdf, n = OUTPUT / f"{base} ({n}).pdf", n + 1
    render_pdf(notes, pdf, info["title"], info["url"])
    audio.unlink(missing_ok=True)  # keep transcript + notes, drop the big audio file
    emit("done", 1.0, pdf=str(pdf), title=info["title"])


if __name__ == "__main__":
    try:
        if len(sys.argv) >= 4 and sys.argv[1] == "--render":
            render_pdf(Path(sys.argv[2]).read_text(), sys.argv[3], *(sys.argv[4:6]))
            emit("done", 1.0, pdf=sys.argv[3])
        elif len(sys.argv) == 2:
            main(sys.argv[1].strip())
        else:
            print(__doc__)
            sys.exit(2)
    except Exception as e:  # report every failure to the app instead of a traceback
        emit("error", message=str(e) or e.__class__.__name__)
        sys.exit(1)
