#!/usr/bin/env bash
#
# `make demo N=<n>` — the one command that produces the measurement.
#
# Brings the platform up, starts N nodes, waits for each to take a DHCP
# lease on the isolated segment, follows each node's serial console through
# the boot phases to the login prompt, takes each node through burn-in and
# the acceptance gate to `active`, waits for it to join Slurm, runs a job
# array across every one of them, and prints the per-phase, per-node timing
# table. The 1-to-N curve is a project deliverable, so the demo records it
# every time rather than only when someone remembers to measure.
#
# Zero manual steps, from power-off to a cluster that takes work. Everything
# here is idempotent, so running it again on a live lab is cheap rather than
# destructive.
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
# shellcheck source=lib/converge.sh
source "$HERE/lib/converge.sh"
lab_load_env
counters_init
timing_init

log "demo with NODE_COUNT=${NODE_COUNT}, run ${LAB_RUN_ID}"

timed platform-up "" -- bash "$HERE/up.sh"

# The roles own the node definitions and the reservations, and the node
# count is a variable they read from the environment. Without this, N=4
# would start four VMs but Warewulf would only know the nodes from the last
# converge, and the ones it does not know cannot fetch an iPXE script.
timed converge "" -- converge_run

timed nodes-up    "" -- bash "$HERE/nodes-up.sh"

# A login prompt is not a cluster. A node arrives `staged`, runs its own
# burn-in and waits for the gate; these two phases are the rest of the way to
# a node that can take a job. Both are idempotent: on a lab whose nodes are
# already active they skip, which is why `make demo` twice is cheap.
timed nodes-activate "" -- bash "$HERE/nodes-activate.sh"
timed slurm-ready    "" -- bash "$HERE/slurm-ready.sh"

echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"

echo
log "Slurm-ready. 'make nodes-down' to stop the nodes, 'make down' for everything."
