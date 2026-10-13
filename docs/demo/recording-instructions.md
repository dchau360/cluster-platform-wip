# Recording the demo — what is already done, and the one step that is yours

Everything except the voice is in this directory. This page is the exact
recipe for the last step: record your voice over the real terminal run and
put the result somewhere the README can link.

You do **not** need to touch the lab host for this. The terminal run is
already recorded, scrubbed and committed.

## What is already here

| File | What it is |
| --- | --- |
| `make-demo-n2.cast` | The real `make demo N=2` run on the lab host, 1:35, no shell prompt in it. Replays in a browser. |
| `make-demo-n2.txt` | The same run as plain text, for reading. |
| `timings-20261013T000455Z-686422.cast` | The stored `N=4` timing table, reprinted (not a second live run). |
| `timings-20261013T000455Z-686422.txt` | The same table as plain text. |
| `narration.md` | The five-minute script, with video timestamps and cast positions. |

GitHub does not replay `.cast` files, so replay one locally with the
`asciinema` player — or read the `.txt` beside it, which is the same output
with the escape sequences removed. On a machine with `asciinema` installed:

```sh
asciinema play docs/demo/make-demo-n2.cast
asciinema play docs/demo/timings-20261013T000455Z-686422.cast
```

## Exactly what to run

```sh
# 1. Read the script once, out loud, with a stopwatch. Trim nothing; it is
#    written to land at about 5:00 at 150 words a minute.
open docs/demo/narration.md

# 2. Have the cast ready to play at 1x in a terminal you are happy to film.
asciinema play docs/demo/make-demo-n2.cast
```

If you would rather capture a fresh run than reuse the committed one, record
it on the lab host (this is the same path that produced the committed cast,
and it writes no shell prompt into the file):

```sh
set -a; . lab/local.env; set +a
ssh "$LAB_HOST_SSH" 'wsl -d Ubuntu bash -lc "cd ~/src/cluster-platform-wip && make record-demo N=2"'
```

That replaces `docs/demo/make-demo-n2.cast` and its `.txt`. It is safe to
run again; a second run of the demo is idempotent.

## Where to speak

Follow `narration.md` top to bottom. Each section names a **Video** time and
a **Cast** position:

- At the section's video time, start talking.
- Put the cast at the named position and let it play at 1x.
- When the script says *hold*, pause the cast and keep talking. The
  narration is longer than the terminal for the parts that explain why a
  number matters; the pauses are deliberate.
- At 3:50 switch the visual from `make-demo-n2.cast` to the `N=4` timing
  cast for the rest of the video.

Do not read the headings or this file aloud. Lead with the result, exactly
as the first section does.

## Where to upload the finished video

Pick one:

1. **YouTube, unlisted** — recommended, because the README can link it and
   the video does not appear in search. Upload the exported MP4, set
   visibility to *Unlisted*, copy the watch URL.
2. **A GitHub Release asset** — attach the MP4 to a tagged release on
   `dchau360/cluster-platform-wip`. The URL is stable and stays in the same
   public repository as the code.

Then add the link to the README, in the "Watch the demo" section near the
top, replacing the `<!-- narrated video: ... -->` placeholder comment:

```md
<!-- narrated video: replace this comment with a link once the voice-over is uploaded -->
```

Open a pull request with that one-line README change and merge it. Nothing
else needs to change.

## What not to do

- Do not add host-specific values to anything you upload. The committed cast
  passed `make lint`; a screen recording that shows your shell prompt would
  not. Film the cast, not a live shell.
- Do not re-run the demo from inside the recording to "make it look live" —
  the committed cast *is* the live run.
- Do not edit the `.cast` or `.txt` files. They are evidence.
