#!/usr/bin/env bash
#
# Assert that `make up` is idempotent: run it twice and require the second
# run to report changed=0.
#
# This is a gate, not a report. If the second run changes anything, some
# step is rebuilding instead of reconciling, and every later task inherits
# the problem.

set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT"

run_up() {
  local label="$1" logfile="$2"
  echo "=============================================================="
  echo "$label"
  echo "=============================================================="
  make up 2>&1 | tee "$logfile"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_up "run 1 of make up" "$tmp/up1.log"
echo
run_up "run 2 of make up" "$tmp/up2.log"

result="$(grep -E '^RESULT: changed=' "$tmp/up2.log" | tail -1 || true)"
[[ -n "$result" ]] || { echo "FAIL: run 2 printed no RESULT line"; exit 1; }

changed="${result#RESULT: changed=}"
changed="${changed%% *}"

echo
echo "=============================================================="
echo "run 1: $(grep -E '^RESULT: changed=' "$tmp/up1.log" | tail -1)"
echo "run 2: $result"
if [[ "$changed" != "0" ]]; then
  echo "FAIL: second 'make up' changed $changed thing(s). It must change nothing."
  echo "--- changed lines from run 2 ---"
  grep -E '^changed' "$tmp/up2.log" || true
  exit 1
fi
echo "PASS: second 'make up' changed nothing"
