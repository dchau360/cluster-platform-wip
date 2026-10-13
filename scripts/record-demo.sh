#!/usr/bin/env bash
#
# Record the demo as an asciinema cast that is safe to commit.
#
# Why a cast and not a video: a cast is text. It replays in a browser at the
# real pace of the real run, a reader can select and copy a line out of it,
# it diffs, and it is a few tens of kilobytes rather than a hundred
# megabytes. A video of a terminal is a worse terminal.
#
# Why a script and not a one-off command: a terminal recording of this lab
# captures the shell prompt, the home directory and the hostname, and these
# repositories are public. Recording by hand is one forgotten `--command`
# away from committing the host's username forever. So the recording path is
# code, it runs with no shell inside the recording at all (see
# lib/demo-cast-driver.sh), and it scrubs what it produces and then checks
# its own work before it writes the file anyone could commit.
#
# `make lint` is still the proof. This script only makes it likely to pass:
# scripts/check-no-host-values.sh is the gate that decides, and it runs over
# the tracked cast in CI.
#
# Usage:
#   scripts/record-demo.sh demo       <node-count> [out.cast]
#   scripts/record-demo.sh timings    <run-id>     [out.cast]
#   scripts/record-demo.sh transcript <cast>       [out.txt]
#
# The `timings` form re-prints the table of a run that already happened,
# from its stored NDJSON. That is how the N=4 table gets into the demo
# package without pretending to be a second live run.
#
# Every cast is written with a plain-text transcript beside it, because
# GitHub renders a `.cast` as the JSON it is. The transcript is what a
# reader with no tooling and twenty minutes actually reads; the cast is for
# the one who wants to watch it happen. The `transcript` form re-renders one
# from a cast that already exists, and needs no lab.

export LAB_SCRIPT_NAME=record-demo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

mode="${1:-}"
arg="${2:-}"
out="${3:-}"

# A cast is a JSON header plus one JSON array per output event. This renders
# the output stream back to the text a terminal would have shown, dropping
# the escape sequences that only mean something to a terminal: colour,
# cursor moves, and the carriage returns a progress line uses to overwrite
# itself. A line that was overwritten in the live run is kept, because in a
# transcript the intermediate state is information rather than flicker.
write_transcript() {
  local cast="$1" txt="$2"
  python3 - "$cast" "$txt" <<'PY'
import json
import re
import sys

cast_path, txt_path = sys.argv[1:3]

with open(cast_path, encoding="utf-8") as fh:
    fh.readline()
    text = "".join(json.loads(line)[2] for line in fh if line.strip())

text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)   # CSI
text = re.sub(r"\x1b[\]P][^\x07\x1b]*(\x07|\x1b\\)?", "", text)  # OSC / DCS
text = re.sub(r"\x1b[()][0-9A-B]", "", text)            # charset select
text = re.sub(r"\x1b[=>MD78]", "", text)
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"\n{3,}", "\n\n", text)

with open(txt_path, "w", encoding="utf-8") as fh:
    fh.write(text)
print(f"transcript: {sum(1 for _ in open(txt_path, encoding='utf-8'))} lines")
PY
}

case "$mode" in
  demo)
    [[ "$arg" =~ ^[0-9]+$ ]] || die "usage: record-demo.sh demo <node-count> [out.cast]"
    out="${out:-$REPO_ROOT/docs/demo/make-demo-n$arg.cast}"
    title="make demo N=$arg — cluster-platform-wip"
    ;;
  timings)
    [[ -n "$arg" ]] || die "usage: record-demo.sh timings <run-id> [out.cast]"
    [[ -f "$LAB_TIMING_DIR/$arg.ndjson" ]] \
      || die "no stored run $arg in $LAB_TIMING_DIR"
    out="${out:-$REPO_ROOT/docs/demo/timings-$arg.cast}"
    title="make timings RUNID=$arg — cluster-platform-wip"
    ;;
  transcript)
    [[ -f "$arg" ]] || die "usage: record-demo.sh transcript <cast> [out.txt]"
    out="${out:-${arg%.cast}.txt}"
    write_transcript "$arg" "$out"
    log "transcript: $out"
    exit 0
    ;;
  *)
    die "usage: record-demo.sh {demo <node-count>|timings <run-id>|transcript <cast>} [out]"
    ;;
esac

command -v asciinema >/dev/null 2>&1 \
  || die "asciinema not found. 'sudo apt-get install -y asciinema'. The fallback is 'script -t', which does not replay in a browser."
command -v python3 >/dev/null 2>&1 || die "python3 not found; the scrub pass needs it"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
raw="$tmp/raw.cast"
needles="$tmp/needles.tsv"
: >"$needles"
chmod 600 "$needles"

# needle<TAB>replacement<TAB>ci|cs
#
# `ci` only for the hostname: Windows reports it in one case and some tools
# lower-case it, and both spellings identify the same machine.
add_needle() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-cs}" >>"$needles"; }

# ---------------------------------------------------------------------------
# What gets scrubbed
#
# The same values scripts/check-no-host-values.sh check 4 searches tracked
# files for, chosen the same way: a variable listed in lab/host-specific.vars
# unconditionally and each @-separated half of it, and any other variable
# whose value differs from the one the example ships. A value identical to
# the example is a shared default, not a host value, and replacing it would
# only make the recording a worse description of the run.
#
# Plus three things that are host-specific without being variables at all:
# the home directory, the user who ran the recording, and the hostname.
# ---------------------------------------------------------------------------
declare -A HOST_SPECIFIC=()
while IFS= read -r name; do
  [[ -n "$name" ]] && HOST_SPECIFIC["$name"]=1
done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO_ROOT/lab/host-specific.vars" \
         | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || true)

# Same rule the shell itself uses: a '#' only starts a comment when
# whitespace precedes it, so `VAR=#notacomment` keeps its value.
unquote() {
  local v="$1"
  [[ "$v" =~ ^(.*[[:space:]])#.*$ ]] && v="${BASH_REMATCH[1]}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

declare -A EXAMPLE_VAL=()
while IFS='=' read -r k v; do
  [[ -n "$k" ]] && EXAMPLE_VAL["$k"]="$(unquote "$v")"
done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$LAB_ENV_EXAMPLE" || true)

if [[ -f "$LAB_ENV_FILE" ]]; then
  while IFS='=' read -r key val; do
    val="$(unquote "$val")"
    [[ -n "$key" && -n "$val" ]] || continue
    if [[ -z "${HOST_SPECIFIC[$key]-}" ]]; then
      [[ "${EXAMPLE_VAL[$key]-$'\x01'}" != "$val" ]] || continue
      (( ${#val} >= 4 )) || continue
      [[ ! "$val" =~ ^[0-9]+$ ]] || continue
    fi
    add_needle "$val" "<redacted:$key>"
    if [[ -n "${HOST_SPECIFIC[$key]-}" && "$val" == *@* ]]; then
      while IFS= read -r part; do
        (( ${#part} >= 4 )) && add_needle "$part" "<redacted:$key>"
      done < <(printf '%s\n' "${val//@/$'\n'}")
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$LAB_ENV_FILE" || true)
fi

host_fqdn="$(hostname 2>/dev/null || true)"
host_short="${host_fqdn%%.*}"
[[ ${#host_short} -ge 3 ]] && add_needle "$host_short" "lab-host" ci
[[ -n "$host_fqdn" && "$host_fqdn" != "$host_short" ]] && add_needle "$host_fqdn" "lab-host" ci

# $HOME before the username, so /home/<user> becomes /home/lab in one piece
# rather than /home/lab/... twice over.
[[ -n "${HOME:-}" && "$HOME" != "/" ]] && add_needle "$HOME" "/home/lab"
user_name="${LAB_WSL_USER:-$(id -un)}"
[[ ${#user_name} -ge 3 ]] && add_needle "$user_name" "lab"

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$out")"

# Fixed geometry, so the cast reads the same in a browser as it did here and
# the timing table (55 columns) never wraps.
log "recording: $title"
export CAST_STATUS_FILE="$tmp/status"
asciinema rec \
  --overwrite --yes \
  --cols 100 --rows 34 \
  --title "$title" \
  --command "bash $HERE/lib/demo-cast-driver.sh $mode $arg" \
  "$raw" </dev/null

# No --idle-time-limit: the cast replays at the pace of the real run, so the
# narration script can be keyed to it and the silences are the silences an
# operator actually waits through. A viewer who wants it faster has
# `asciinema play -i 2` and the player's speed control.

# ---------------------------------------------------------------------------
# Scrub, then check the scrub
#
# Into a temporary file first, and only then over the committable one. The
# scrub has to run before anything about this recording is printed or kept,
# including the tail of a failed run, because a failure message is as likely
# to carry a path under $HOME as a successful one.
# ---------------------------------------------------------------------------
scrubbed="$tmp/scrubbed.cast"
python3 - "$raw" "$needles" "$scrubbed" <<'PY'
import re
import sys

raw_path, needles_path, out_path = sys.argv[1:4]

needles = []
with open(needles_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        needle, replacement, flags = line.split("\t")
        if needle:
            needles.append((needle, replacement, flags))

# Longest first: a home directory contains the username, and replacing the
# username first would leave a half-scrubbed path that no longer matches.
needles.sort(key=lambda n: len(n[0]), reverse=True)

text = open(raw_path, encoding="utf-8").read()
hits = {}
for needle, replacement, flags in needles:
    pattern = re.compile(re.escape(needle), re.IGNORECASE if flags == "ci" else 0)
    text, count = pattern.subn(replacement, text)
    if count:
        hits[replacement] = hits.get(replacement, 0) + count

# Check the work. A needle that survives its own substitution means the
# scrub is broken, and the file must not be written.
survivors = [
    replacement
    for needle, replacement, flags in needles
    if re.search(re.escape(needle), text, re.IGNORECASE if flags == "ci" else 0)
]
if survivors:
    print("error: scrub left a host value in the cast: " + ", ".join(sorted(set(survivors))),
          file=sys.stderr)
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(text)

# Only ever the placeholder and a count. Never the value.
for replacement, count in sorted(hits.items()):
    print(f"scrubbed {count:5d}  {replacement}")
if not hits:
    print("scrubbed     0  (nothing host-specific appeared in the recording)")
PY

# ---------------------------------------------------------------------------
# Did the thing being recorded actually work?
#
# asciinema exits 0 whether the command it recorded succeeded or printed a
# stack trace, so without this a broken run produces a tidy, committable
# cast of its own error message. The driver writes its exit status out of
# band; an absent status file means the driver never reached the end.
# ---------------------------------------------------------------------------
cast_status="$(cat "$CAST_STATUS_FILE" 2>/dev/null || echo missing)"
if [[ "$cast_status" != "0" ]]; then
  echo
  echo "--- last 25 lines of the recording (scrubbed) ---" >&2
  python3 - "$scrubbed" <<'PY' >&2 || true
import json
import sys

out = []
with open(sys.argv[1], encoding="utf-8") as fh:
    fh.readline()
    for line in fh:
        line = line.strip()
        if line:
            out.append(json.loads(line)[2])
print("".join(out)[-4000:])
PY
  die "the recorded command exited $cast_status; no cast written to $out"
fi

mv "$scrubbed" "$out"
write_transcript "$out" "${out%.cast}.txt"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
duration="$(python3 - "$out" <<'PY'
import json
import sys

last = 0.0
with open(sys.argv[1], encoding="utf-8") as fh:
    fh.readline()
    for line in fh:
        line = line.strip()
        if line:
            last = json.loads(line)[0]
print(f"{int(last // 60)}m{last % 60:04.1f}s")
PY
)"

echo
log "cast:     $out"
log "text:     ${out%.cast}.txt"
log "duration: $duration  (replays 1:1 with the real run)"
log "size:     $(du -h "$out" | cut -f1)"
log "next:     make lint   # scripts/check-no-host-values.sh is the proof, not this script"
