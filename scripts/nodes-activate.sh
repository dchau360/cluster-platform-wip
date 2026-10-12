#!/usr/bin/env bash
#
# Take every freshly-provisioned node from `staged` to `active`, so `make
# demo` ends at a cluster rather than at a login prompt.
#
# This is the step that exists because the design refuses to shortcut it. A
# new node is `staged` in NetBox; `staged` means burn-in, and a node in
# burn-in must not take jobs, so `slurm_compute` deliberately leaves slurmd
# stopped there. Three things therefore have to happen in order, and no
# manual step is one of them:
#
#   1. The node runs its own burn-in and posts the raw measurements to the
#      head-node API, which writes them to its NetBox device.
#   2. The burn-in gate judges those measurements on the head node and sets
#      the status: `active` if every floor is met, `failed` otherwise. The
#      node is never asked for its own verdict.
#   3. A promoted node re-pulls, sees `active`, and starts slurmd.
#
# Step 3 is the one with a choice in it. The node's own pull timer would get
# there within PULL_INTERVAL plus its splay — correct, and up to twenty
# minutes. Nobody can log in to a node to hurry it along, so the lever used
# instead is power: a promoted node is power-cycled, and its boot run of
# cluster-pull starts as soon as the network is up. That is also what a real
# burn-in-to-production transition does.
#
# A node NetBox already calls `active` is left alone: it started slurmd on
# its first boot, and there is nothing to promote.

export LAB_SCRIPT_NAME=nodes-activate
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/boot-phases.sh
source "$HERE/lib/boot-phases.sh"
# shellcheck source=lib/netbox.sh
source "$HERE/lib/netbox.sh"
# shellcheck source=lib/node-reboot.sh
source "$HERE/lib/node-reboot.sh"
lab_load_env

# "<rack-position> <device> <status> <has-burnin-results>" per compute node.
#
# The rack position is the join key, not the name. NetBox names a device by
# where it is racked (`rack-a-u01`) and the seeder sets its position to the
# node index, so position is how a node index finds its device without this
# script having to know either naming scheme.
node_rows() {
  netbox_get '/api/dcim/devices/?role=compute&limit=0' 2>/dev/null \
    | python3 -c '
import json, sys
for d in sorted(json.load(sys.stdin)["results"], key=lambda d: d["name"]):
    c = d.get("custom_fields") or {}
    pos = d.get("position")
    print(int(float(pos)) if pos is not None else -1,
          d["name"], d["status"]["value"], "yes" if c.get("burnin_results") else "no")
' 2>/dev/null || true
}

mapfile -t ROWS < <(node_rows)
if (( ${#ROWS[@]} == 0 )); then
  warn "NetBox returned no compute devices; nothing to activate"
  exit 0
fi

declare -A STATUS=() HAS_BURNIN=() DEVICE_AT=()
for row in "${ROWS[@]}"; do
  read -r pos dev status burnin <<<"$row"
  STATUS["$dev"]="$status"
  HAS_BURNIN["$dev"]="$burnin"
  DEVICE_AT["$pos"]="$dev"
done

# Only the nodes this run is responsible for. A device for a node index above
# NODE_COUNT is not booted, so waiting for its burn-in would wait forever.
staged=()
for i in $(lab_node_indexes); do
  name="$(node_name "$i")"
  dev="${DEVICE_AT[$i]:-}"
  [[ -n "$dev" ]] || { warn "no NetBox device at rack position $i for $name"; continue; }
  case "${STATUS[$dev]:-unknown}" in
    active) ok "$name ($dev) is already active" ;;
    staged) staged+=("$i:$name:$dev") ;;
    *)      warn "$name ($dev) is '${STATUS[$dev]:-unknown}', neither staged nor active" ;;
  esac
done

if (( ${#staged[@]} == 0 )); then
  log "no staged node to promote"
  exit 0
fi

log "${#staged[@]} staged node(s) to take through burn-in"

# ---------------------------------------------------------------------------
# 1. Wait for the nodes' own burn-in measurements to reach NetBox
# ---------------------------------------------------------------------------

declare -A PENDING=()
for entry in "${staged[@]}"; do
  IFS=: read -r _ name dev <<<"$entry"
  if [[ "${HAS_BURNIN[$dev]}" == yes ]]; then
    phase_skip burnin-report "$name" "measurements already in NetBox"
  else
    PENDING["$dev"]="$name"
    phase_begin burnin-report "$name"
  fi
done

if (( ${#PENDING[@]} > 0 )); then
  log "waiting up to ${BURNIN_REPORT_TIMEOUT}s for ${#PENDING[@]} node(s) to post burn-in results"
  deadline=$(( $(date +%s) + BURNIN_REPORT_TIMEOUT ))
  while (( ${#PENDING[@]} > 0 )) && (( $(date +%s) < deadline )); do
    while read -r _ dev _ burnin; do
      [[ -n "${PENDING[$dev]-}" ]] || continue
      if [[ "$burnin" == yes ]]; then
        phase_end burnin-report "${PENDING[$dev]}" ok
        ok "${PENDING[$dev]} posted its burn-in measurements"
        unset 'PENDING[$dev]'
      fi
    done < <(node_rows)
    (( ${#PENDING[@]} == 0 )) || sleep 5
  done
fi

reported_all=1
for dev in "${!PENDING[@]}"; do
  phase_end burnin-report "${PENDING[$dev]}" fail
  warn "${PENDING[$dev]} posted no burn-in measurements in ${BURNIN_REPORT_TIMEOUT}s"
  reported_all=0
done

# ---------------------------------------------------------------------------
# 2. The gate judges them
# ---------------------------------------------------------------------------

echo
timed burnin-gate "" -- bash "$HERE/day2.sh" burnin_gate

# ---------------------------------------------------------------------------
# 3. A promoted node re-pulls. A power cycle is the fastest honest way to
#    make that happen on a node nobody can log in to.
# ---------------------------------------------------------------------------

mapfile -t ROWS < <(node_rows)
for row in "${ROWS[@]}"; do
  read -r _ dev status _ <<<"$row"
  STATUS["$dev"]="$status"
done

echo
promoted=() held=()
for entry in "${staged[@]}"; do
  IFS=: read -r _ name dev <<<"$entry"
  case "${STATUS[$dev]:-unknown}" in
    active) promoted+=("$name") ;;
    failed) held+=("$name"); warn "the gate failed $name ($dev); it will not join Slurm" ;;
    *)      held+=("$name"); warn "$name ($dev) is still '${STATUS[$dev]:-unknown}' after the gate" ;;
  esac
done

for name in ${promoted[@]+"${promoted[@]}"}; do
  log "power-cycling $name so its boot pull run sees 'active' and starts slurmd"
  phase_begin node-activate "$name"
  node_stop "$name"
  node_boot "$name"
  watch_pid="$NODE_BOOT_WATCH_PID"
  if node_wait_for_console "$name" 'login:' "$BOOT_PHASE_TIMEOUT"; then
    phase_end node-activate "$name" ok
  else
    phase_end node-activate "$name" fail
    warn "$name did not reach a login prompt after the power cycle"
  fi
  wait "$watch_pid" 2>/dev/null || true
done

echo
printf 'promoted to active: %s\n' "${promoted[*]:-none}"
printf 'held by the gate  : %s\n' "${held[*]:-none}"

(( reported_all == 1 )) || die "not every staged node reported its burn-in"
(( ${#held[@]} == 0 ))  || die "${#held[@]} node(s) did not pass the burn-in gate"
echo "ACTIVATION OK — every staged node passed burn-in and was promoted"
