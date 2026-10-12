#!/usr/bin/env bash
#
# Single-node re-provision does not disturb its neighbours — acceptance
# criterion #7.
#
#   make drill-reprovision [NODE=<index>] [N=<n>]
#
# One node is torn down to bare metal: powered off, undefined, and its disk
# removed, so it re-provisions from the network. The other nodes are not
# touched. The proof is quantitative rather than "it looked fine":
#
#   * every neighbour was `running` before, during and after
#   * every neighbour's QEMU CPU time increased across the window, so its
#     guest never restarted (a reboot would reset it)
#   * every neighbour's serial console kept growing, so it was not truncated
#     by anything re-starting it
#   * the re-provisioned node's CPU time and console both reset, so the drill
#     really did replace it rather than restart it

export LAB_SCRIPT_NAME=drill-reprovision
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/boot-phases.sh
source "$HERE/lib/boot-phases.sh"
# shellcheck source=lib/node-reboot.sh
source "$HERE/lib/node-reboot.sh"
lab_load_env

INDEX="${NODE:-1}"
if [[ ! "$INDEX" =~ ^[0-9]+$ ]] || (( INDEX < 1 )); then
  die "NODE must be a positive integer"
fi
target="$(node_name "$INDEX")"
(( NODE_COUNT >= 2 )) || die "need at least N=2 to show a neighbour is undisturbed"

counters_init
timing_init

guest_cpu_ns() {
  "${VIRSH[@]}" domstats "$1" --cpu-total 2>/dev/null \
    | awk -F= '/cpu.time=/{print $2}' | head -1
}

snap_field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

neighbour_snapshot() {
  local name
  for i in $(lab_node_indexes); do
    name="$(node_name "$i")"
    [[ "$name" == "$target" ]] && continue
    printf '%s state=%s cpu_ns=%s console_bytes=%s lease=%s\n' \
      "$name" \
      "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || echo missing)" \
      "$(guest_cpu_ns "$name")" \
      "$(sudo stat -c %s "$(node_console_path "$name")" 2>/dev/null || echo 0)" \
      "$(sudo grep -icE "$(node_mac "$i")" "$LAB_STATE_DIR/dnsmasq/leases" 2>/dev/null || echo 0)"
  done
}

echo "=============================================================="
echo "before: $target will be re-provisioned, the rest must not move"
echo "=============================================================="
neighbour_snapshot > /dev/null
before="$(neighbour_snapshot)"
printf '%s\n' "$before"

echo
echo "=============================================================="
echo "re-provision $target: power off, undefine, wipe the disk, boot fresh"
echo "=============================================================="
phase_begin reprovision-stop "$target"
node_stop "$target"
"${VIRSH[@]}" undefine --nvram "$target" >/dev/null 2>&1 || true
sudo rm -f "$LAB_VM_DIR/${target}.qcow2" "$LAB_VM_DIR/nvram/${target}.fd"
phase_end reprovision-stop "$target"
changed "domain $target undefined and its disk removed"

# nodes-up defines and starts only the nodes that are not already running, so
# the neighbours are skipped and the wiped node takes the full provisioning
# path again. It also waits for the target's DHCP lease and login prompt.
timed reprovision-boot "$target" -- bash "$HERE/nodes-up.sh"

echo
echo "=============================================================="
echo "after"
echo "=============================================================="
after="$(neighbour_snapshot)"
printf '%s\n' "$after"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

while read -r name _; do
  [[ "$name" == "$target" ]] && continue
  [[ -n "$name" ]] || continue
  before_line="$(printf '%s\n' "$before" | awk -v n="$name" '$1==n{print}')"
  after_line="$(printf '%s\n' "$after" | awk -v n="$name" '$1==n{print}')"

  if [[ "$(snap_field "$after_line" state)" != "running" ]]; then
    fail "$name is not running after the re-provision"
  fi
  if (( $(snap_field "$after_line" cpu_ns) <= $(snap_field "$before_line" cpu_ns) )); then
    fail "$name's CPU time did not increase — it restarted"
  fi
  if (( $(snap_field "$after_line" console_bytes) <= $(snap_field "$before_line" console_bytes) )); then
    fail "$name's console did not grow — it was restarted or truncated"
  fi
  if [[ "$(snap_field "$after_line" lease)" == "0" ]]; then
    fail "$name lost its DHCP lease"
  fi
  printf 'ok   %s: state=%s cpu_ns %s->%s console_bytes %s->%s lease=%s\n' \
    "$name" "$(snap_field "$after_line" state)" \
    "$(snap_field "$before_line" cpu_ns)" "$(snap_field "$after_line" cpu_ns)" \
    "$(snap_field "$before_line" console_bytes)" "$(snap_field "$after_line" console_bytes)" \
    "$(snap_field "$after_line" lease)"
done <<< "$after"

echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"

if (( fails > 0 )); then
  die "$fails neighbour(s) were disturbed"
fi
printf '%sRE-PROVISION OK%s — %s was rebuilt from bare metal; every neighbour stayed up\n' \
  "$_C_GRN" "$_C_RST" "$target"
