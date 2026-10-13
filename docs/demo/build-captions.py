#!/usr/bin/env python3
"""Build the narration caption tracks from `narration.md`.

The demo ships without a voice-over. The narration still exists, so it is
also published as closed captions in the two formats a player wants: SRT
(universally accepted) and WebVTT (the HTML5 `<track>` format).

The captions are generated from the same source as the script, so the two
cannot drift. The spoken text is timed at a steady 144 words a minute
(2.4 words a second), which puts the 720-word script on a five-minute
timeline. The generator also prints the true start time of each section,
which is what the headings in `narration.md` quote.

Usage:
    python3 docs/demo/build-captions.py

Writes `docs/demo/narration.srt` and `docs/demo/narration.vtt` next to
`narration.md`.
"""

from __future__ import annotations

import os
import re
import sys

WPS = 2.4  # words per second; 720 words / 2.4 = 300s = 5:00
MAX_WORDS = 12  # a caption cue this long or shorter
MAX_LINE = 42  # characters per caption line, two lines at most

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "narration.md")


def parse_sections(path: str) -> list[dict]:
    text = open(path, encoding="utf-8").read()
    # The spoken script is everything after the first standalone rule; the
    # preamble explains how to use the two clocks and is not read aloud.
    body = text.split("\n---\n", 1)[1]
    sections = []
    for part in re.split(r"(?m)^## ", body):
        if not part.strip():
            continue
        lines = part.split("\n")
        heading = lines[0].strip()
        # Drop the leading "m:ss — " so the title survives a re-time.
        title = re.sub(r"^\d+:\d\d\s*[—-]\s*", "", heading).strip()
        spoken = " ".join(line.strip() for line in lines[1:] if line.strip())
        spoken = re.sub(r"\s+", " ", spoken).strip()
        if spoken:
            sections.append({"title": title, "text": spoken})
    return sections


def wrap(text: str) -> str:
    words, lines, current = text.split(), [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if current and len(candidate) > MAX_LINE:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return "\n".join(lines)


def fits(words: list[str]) -> bool:
    """True when these words render as a cue of at most two caption lines."""
    return len(words) <= MAX_WORDS and len(wrap(" ".join(words)).split("\n")) <= 2


def pack_words(words: list[str]) -> list[str]:
    cues: list[str] = []
    current: list[str] = []
    for word in words:
        if current and not fits(current + [word]):
            cues.append(" ".join(current))
            current = []
        current.append(word)
    if current:
        cues.append(" ".join(current))
    return cues


def cues_for(section: str) -> list[str]:
    """Split spoken text into caption-sized cues.

    A sentence that fits is one cue. A longer one is broken at the
    punctuation a reader would pause at, then those pieces are packed back
    towards a full cue, so a comma only starts a new cue when the cue is
    already two lines. Nothing is split unless it has to be.
    """
    cues: list[str] = []
    for sentence in re.split(r"(?<=[.!?])\s+", section):
        sentence = sentence.strip()
        if not sentence:
            continue
        words = sentence.split()
        if fits(words):
            cues.append(" ".join(words))
            continue

        pieces = [
            piece.strip()
            for piece in re.split(r"(?<=[;:,])\s+|\s+—\s+", sentence)
            if piece.strip()
        ]
        current: list[str] = []
        for piece in pieces:
            piece_words = piece.split()
            if fits(piece_words):
                if current and not fits(current + piece_words):
                    cues.append(" ".join(current))
                    current = []
                current.extend(piece_words)
            else:
                if current:
                    cues.append(" ".join(current))
                    current = []
                packed = pack_words(piece_words)
                cues.extend(packed[:-1])
                current = packed[-1].split() if packed else []
        if current:
            cues.append(" ".join(current))
    return cues


def stamp(seconds: float, sep: str) -> str:
    ms = int(round(seconds * 1000))
    h, rem = divmod(ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def main() -> int:
    sections = parse_sections(SOURCE)
    if not sections:
        print("no spoken sections found in", SOURCE, file=sys.stderr)
        return 2

    cues: list[dict] = []
    now = 0.0
    starts: list[tuple[str, float]] = []
    for section in sections:
        starts.append((section["title"], now))
        for chunk in cues_for(section["text"]):
            duration = len(chunk.split()) / WPS
            cues.append({"start": now, "end": now + duration, "text": wrap(chunk)})
            now += duration
    total = now

    srt = os.path.join(HERE, "narration.srt")
    vtt = os.path.join(HERE, "narration.vtt")
    with open(srt, "w", encoding="utf-8") as fh:
        for i, cue in enumerate(cues, 1):
            fh.write(f"{i}\n{stamp(cue['start'], ',')} --> {stamp(cue['end'], ',')}\n{cue['text']}\n\n")
    with open(vtt, "w", encoding="utf-8") as fh:
        fh.write("WEBVTT\n\n")
        for cue in cues:
            fh.write(f"{stamp(cue['start'], '.')} --> {stamp(cue['end'], '.')}\n{cue['text']}\n\n")

    print(f"narration.srt: {len(cues)} cues, {len(' '.join(c['text'] for c in cues).split())} words")
    print(f"narration.vtt: {len(cues)} cues")
    shortest = min(len(c["text"].split()) for c in cues)
    print(f"total: {int(total // 60)}:{total % 60:04.1f}  (shortest cue {shortest} word(s))")
    for title, start in starts:
        print(f"  {int(start // 60)}:{int(start % 60):02d}  {title}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
