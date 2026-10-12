#!/usr/bin/env bash
#
# `make acceptance` — run the acceptance drills in the order the parent task
# lists them, so one command produces every piece of evidence.
#
#   1. N=2 then N=4 from the same code, recording boot-phase timings.
#   2. One-command image rollback (needs TAG=<previous tag>).
#   3. Single-node re-provision with the neighbours left running.
#   4. A NIC swap with the hostname and NetBox identity held fixed.
#
# It does not hide a failure: the first drill that fails stops the run, so a
# partial record is never mistaken for a complete one.

export LAB_SCRIPT_NAME=acceptance
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

runner() { printf '\n\n######## %s ########\n\n' "$*"; }

for count in 2 4; do
  runner "N=$count — same code, $count nodes"
  N="$count" bash "$HERE/nodes-down.sh"
  N="$count" bash "$HERE/demo.sh"
done

if [[ -n "${TAG:-}" ]]; then
  runner "rollback to $TAG — one command, then read the tag back"
  bash "$HERE/rollback.sh"
else
  runner "rollback skipped — set TAG=sha-<previous> to run it"
fi

runner "single-node re-provision — neighbours must stay up"
bash "$HERE/drill-reprovision.sh"

runner "NIC swap — identity must not follow the MAC"
bash "$HERE/drill-nic-swap.sh"

runner "acceptance drills complete"
