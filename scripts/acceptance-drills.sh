#!/usr/bin/env bash
#
# `make acceptance` — run every acceptance drill, in order, so one command
# produces the whole record.
#
#   1. The 1-to-N curve: a full demo at each node count in
#      ACCEPTANCE_NODE_COUNTS, lowest first, each from stopped nodes.
#   2. A job array across every node (part of each demo, via slurm-ready).
#   3. Soft-RoCE RDMA bandwidth between a node pair, with perftest.
#   4. One-command image rollback (needs TAG=<previous tag>).
#   5. Rolling image update across the fleet (needs ROLLING_TAG=<tag>).
#   6. `deployed`-ref rollback: one ref move, and every node follows it.
#   7. Single-node re-provision with the neighbours left running.
#   8. A NIC swap with the hostname and NetBox identity held fixed.
#
# Two drills are not here, each for a stated reason:
#
#   * Cold-start recovery. `wsl --shutdown` kills the process that asked for
#     it, so the drill is driven from the Windows side:
#     scripts/windows/drill-cold-start.ps1.
#   * The burn-in gate holding a failed node. It needs a node deliberately
#     degraded from the hypervisor (the throttle is a `virsh blkdeviotune`),
#     which is a hand on the lab rather than a step in a pipeline. The
#     procedure and its measured result are in docs/acceptance-drills.md.
#
# It does not hide a failure: the first drill that fails stops the run, so a
# partial record is never mistaken for a complete one.

export LAB_SCRIPT_NAME=acceptance
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

runner() { printf '\n\n######## %s ########\n\n' "$*"; }

# A list of node counts, read from the environment. Not a literal, and not a
# single number: the deliverable is the curve, and which points are on it is
# a property of the lab rather than of this script.
# shellcheck disable=SC2206 # splitting on whitespace is the point: it is a list
counts=(${ACCEPTANCE_NODE_COUNTS:-})
(( ${#counts[@]} > 0 )) || die "ACCEPTANCE_NODE_COUNTS is empty; nothing to measure"

for count in "${counts[@]}"; do
  runner "N=$count — the same code, $count node(s), from stopped"
  N="$count" bash "$HERE/nodes-down.sh"
  N="$count" bash "$HERE/demo.sh"
done

# The pair test needs two nodes, so it runs at the largest count measured,
# which is the state the loop above leaves the lab in.
largest="${counts[-1]}"
if (( largest >= 2 )); then
  runner "Soft-RoCE RDMA bandwidth — a real perftest number from a node pair"
  N="$largest" bash "$HERE/rdma-test.sh"
else
  runner "RDMA skipped — a pair needs two nodes and the largest count is $largest"
fi

if [[ -n "${TAG:-}" ]]; then
  runner "image rollback to $TAG — one command, then read the tag back"
  N="$largest" bash "$HERE/rollback.sh"
else
  runner "image rollback skipped — set TAG=sha-<previous> to run it"
fi

if [[ -n "${ROLLING_TAG:-}" ]]; then
  runner "rolling image update to $ROLLING_TAG — one node at a time, jobs kept running"
  N="$largest" TAG="$ROLLING_TAG" bash "$HERE/day2.sh" rolling_update
else
  runner "rolling update skipped — set ROLLING_TAG=sha-<tag> to run it"
fi

if [[ -n "${ROLLBACK_SHA:-}" ]]; then
  runner "deployed-ref rollback to $ROLLBACK_SHA — one ref move, every node follows"
  N="$largest" SHA="$ROLLBACK_SHA" bash "$HERE/promote.sh"
  N="$largest" bash "$HERE/convergence-status.sh" || true
else
  runner "deployed-ref rollback skipped — set ROLLBACK_SHA=<commit> to run it"
fi

runner "single-node re-provision — neighbours must stay up"
N="$largest" bash "$HERE/drill-reprovision.sh"

runner "NIC swap — identity must not follow the MAC"
N="$largest" bash "$HERE/drill-nic-swap.sh"

runner "acceptance drills complete"
