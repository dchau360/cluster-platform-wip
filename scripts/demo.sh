#!/usr/bin/env bash
#
# `make demo N=<n>` — the one command that produces the measurement.
#
# Brings the platform up, starts N nodes, waits for each to take a DHCP
# lease on the isolated segment, follows each node's serial console through
# the boot phases to the login prompt, and prints the per-phase, per-node
# timing table. The 1-to-N curve is a project deliverable, so the demo records
# it every time rather than only when someone remembers to measure.
#
# The console phases are observed live by scripts/lib/boot-phases.sh, which
# nodes-up.sh starts in the background the moment it powers a node on. See
# that file for the phase boundaries.

export LAB_SCRIPT_NAME=demo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
lab_load_env
counters_init
timing_init

log "demo with NODE_COUNT=${NODE_COUNT}, run ${LAB_RUN_ID}"

timed platform-up "" -- bash "$HERE/up.sh"
timed nodes-up    "" -- bash "$HERE/nodes-up.sh"

echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"

echo
log "nodes are running. 'make nodes-down' to stop them, 'make down' for everything."
