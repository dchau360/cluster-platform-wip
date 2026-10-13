#!/usr/bin/env bash
# shellcheck shell=bash
#
# The one command `asciinema rec` runs, for scripts/record-demo.sh.
#
# asciinema records whatever its child writes to the pty. If that child is an
# interactive shell, the first thing in the cast is the prompt, and on this
# lab the prompt carries the host's username and hostname. These repositories
# are public, so the recording starts no shell at all: it prints one neutral
# prompt line for the reader and then runs the real work. There is no prompt
# in the cast because there was never a shell to draw one.
#
# scripts/record-demo.sh still scrubs the cast afterwards, because the demo's
# own output can mention a path under $HOME. Printing no prompt removes the
# one leak scrubbing is worst at spotting: a username stops looking like a
# username the moment it is sitting inside a PS1.
#
# Usage: demo-cast-driver.sh {demo <node-count>|timings <run-id>}

set -uo pipefail

# No brace in these messages: bash ends a `${var:?msg}` expansion at the
# first `}` it sees, so a usage string containing one silently appends the
# rest of itself to the variable's value. That cost a recording once.
mode="${1:?usage: demo-cast-driver.sh demo <node-count> | timings <run-id>}"
arg="${2:?usage: demo-cast-driver.sh demo <node-count> | timings <run-id>}"

cd "${REPO_ROOT:?REPO_ROOT must be set by the recorder}" || exit 2

case "$mode" in
  demo)
    printf '$ make demo N=%s\n' "$arg"
    make demo "N=$arg"
    ;;
  timings)
    printf '$ make timings RUNID=%s\n' "$arg"
    make timings "RUNID=$arg"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
status=$?

# asciinema exits 0 whether the command it recorded worked or not, so the
# recorder cannot tell a successful demo from a recording of a stack trace.
# Report the status out of band rather than printing it into the cast.
[[ -n "${CAST_STATUS_FILE:-}" ]] && printf '%s\n' "$status" >"$CAST_STATUS_FILE"

# An idle prompt at the end, so the replay does not look truncated.
printf '\n$ \n'
exit "$status"
