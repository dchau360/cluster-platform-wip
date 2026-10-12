#!/usr/bin/env bash
#
# Cold-start recovery drill.
#
# `make cold-start-check` asserts that every lab unit is enabled at boot. That
# is the precondition, not the proof. This drill stops the whole distribution
# and measures what comes back by itself, what needs one idempotent command,
# and whether the cluster reaches the same state it was in before.
#
# It is two stages, not one command, and that is a property of what is being
# tested rather than an omission: the thing being restarted is the thing the
# script runs inside. `wsl --shutdown` kills every process in the
# distribution, including this one. The stages are therefore driven from the
# Windows side, which is the only place that survives the restart:
#
#   scripts/windows/drill-cold-start.ps1
#
# and that driver runs:
#
#   bash scripts/drill-cold-start.sh before     # inside WSL
#   wsl --shutdown                              # on Windows
#   bash scripts/drill-cold-start.sh after      # inside WSL, new boot
#
# `before` writes the run id it chose, so `after` records its phases into the
# same timing file across the restart.

export LAB_SCRIPT_NAME=drill-cold-start
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

STAGE="${1:-}"
[[ "$STAGE" == before || "$STAGE" == after ]] \
  || { echo "usage: $(basename "$0") before|after" >&2; exit 2; }

# The run id has to survive the restart, so it is chosen in `before` and read
# back in `after`. LAB_STATE_DIR is on the distribution's own filesystem,
# which a `wsl --shutdown` does not touch.
lab_load_env
DRILL_DIR="$LAB_STATE_DIR/cold-start"
sudo mkdir -p "$DRILL_DIR"
sudo chown "${LAB_WSL_USER:-${USER:-$(id -un)}}" "$DRILL_DIR"

if [[ "$STAGE" == before ]]; then
  LAB_RUN_ID="coldstart-$(date -u +%Y%m%dT%H%M%SZ)"
  export LAB_RUN_ID
  printf '%s\n' "$LAB_RUN_ID" > "$DRILL_DIR/run-id"
else
  [[ -f "$DRILL_DIR/run-id" ]] || die "no $DRILL_DIR/run-id: run the 'before' stage first"
  LAB_RUN_ID="$(cat "$DRILL_DIR/run-id")"
  export LAB_RUN_ID
fi
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"

snapshot() {
  echo "# taken $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "## uptime"
  uptime
  echo "## boot id"
  cat /proc/sys/kernel/random/boot_id
  echo "## domains"
  sudo virsh --connect "$LIBVIRT_URI" list --all 2>/dev/null || true
  echo "## lab units"
  systemctl is-active lab-net.service lab-dnsmasq.service warewulfd.service 2>/dev/null || true
  echo "## slurm"
  sinfo --noheader --Node --format='%N %T' 2>/dev/null || echo "sinfo unavailable"
}

# ---------------------------------------------------------------------------

if [[ "$STAGE" == before ]]; then
  counters_init
  timing_init
  log "recording the state the lab must come back to"
  snapshot | tee "$DRILL_DIR/before.txt"
  echo
  log "pre-restart gate: every lab unit must already be enabled at boot"
  bash "$HERE/cold-start-check.sh"
  printf '%s\n' "$(date +%s)" > "$DRILL_DIR/shutdown-at"
  echo
  log "ready. The driver now runs 'wsl --shutdown' and re-enters the distribution."
  exit 0
fi

# ---------------------------------------------------------------------------
# after
# ---------------------------------------------------------------------------

down_at="$(cat "$DRILL_DIR/shutdown-at" 2>/dev/null || echo 0)"
# The boot id is the only unforgeable evidence that the restart happened.
# Every other signal — uptime, a stopped VM, an inactive unit — can be
# produced without restarting anything.
boot_before="$(grep -A1 '^## boot id$' "$DRILL_DIR/before.txt" | tail -1)"
boot_now="$(cat /proc/sys/kernel/random/boot_id)"

log "boot id before: $boot_before"
log "boot id now   : $boot_now"
if [[ "$boot_before" == "$boot_now" ]]; then
  die "the boot id did not change, so the distribution never restarted. Nothing was measured."
fi
ok "the distribution restarted: a new boot id"
(( down_at > 0 )) && log "seconds from the pre-restart snapshot to this stage: $(( $(date +%s) - down_at ))"

echo
# What came back without being asked. systemd is the first thing to be sure
# of: `degraded` is acceptable (unrelated units on this host fail), `starting`
# is not an answer yet.
phase_begin cold-start-systemd
waited=0
while (( waited < COLD_START_TIMEOUT )); do
  state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == running || "$state" == degraded ]] && break
  sleep 2; waited=$((waited + 2))
done
log "systemd: ${state:-unknown} after ${waited}s"
phase_end cold-start-systemd "" "$( [[ "${state:-}" == running || "${state:-}" == degraded ]] && echo ok || echo fail )"

phase_begin cold-start-units
units_ok=1
for unit in lab-net.service lab-dnsmasq.service; do
  waited=0
  while (( waited < COLD_START_TIMEOUT )) && ! systemctl is-active --quiet "$unit"; do
    sleep 2; waited=$((waited + 2))
  done
  if systemctl is-active --quiet "$unit"; then
    ok "$unit came back by itself (${waited}s)"
  else
    warn "$unit did not come back within ${COLD_START_TIMEOUT}s"
    units_ok=0
  fi
done
phase_end cold-start-units "" "$( ((units_ok == 1)) && echo ok || echo fail )"

echo
log "the gate that says a cold start would recover cleanly"
bash "$HERE/cold-start-check.sh"

echo
# `make up` is idempotent, so running it here is both the repair and the
# measurement of how much repair was needed: a clean cold start changes
# nothing. The change counter is the number to read.
timed cold-start-up "" -- bash "$HERE/up.sh"

echo
# A stopped VM is a powered-off machine. Nothing restores it but a power-on,
# which is the same `nodes-up` any other run uses.
timed cold-start-nodes-up "" -- bash "$HERE/nodes-up.sh"

echo
timed cold-start-slurm "" -- bash "$HERE/slurm-ready.sh"

echo
snapshot | tee "$DRILL_DIR/after.txt"

echo
log "before and after, the part that must match"
before_nodes="$(grep -A"$((NODE_COUNT + 2))" '^## slurm$' "$DRILL_DIR/before.txt" | tail -n +2 | sort || true)"
after_nodes="$(grep -A"$((NODE_COUNT + 2))" '^## slurm$' "$DRILL_DIR/after.txt"  | tail -n +2 | sort || true)"
printf 'before:\n%s\nafter:\n%s\n' "$before_nodes" "$after_nodes"

echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"
echo
echo "COLD START OK — the distribution restarted and the lab came back to Slurm-ready"
