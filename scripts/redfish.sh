#!/usr/bin/env bash
#
# redfish.sh — drive the lab's sushy-emulator over Redfish.
#
# This is the stable client interface for the Redfish deliverable, the one
# the node power/boot automation calls. It speaks Redfish to sushy-emulator,
# which drives libvirt/KVM.
#
#   redfish.sh list
#   redfish.sh status <node>
#   redfish.sh power <node> on|off|cycle
#   redfish.sh boot  <node> pxe|hd|cd|http
#
# <node> is a libvirt domain name (for example cn01). It is resolved to its
# UUID, which is the Redfish Systems member Id sushy-emulator exposes.
#
# Honesty: this offers real power control and real boot-order changes. It is
# NOT a vendor BMC and does not expose vendor BIOS attributes. See
# docs/redfish.md.

export LAB_SCRIPT_NAME=redfish
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

REDFISH_ENDPOINT="${REDFISH_ENDPOINT:-http://${PROV_GW}:${SUSHY_EMULATOR_PORT:-8000}}"
VIRSH=(sudo virsh --connect "$LIBVIRT_URI")

usage() { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

system_id() {
  local node="$1" uuid
  command -v virsh >/dev/null 2>&1 || die "virsh not found"
  uuid="$("${VIRSH[@]}" domuuid "$node" 2>/dev/null | tr -d '\r\n')"
  [[ -n "$uuid" ]] || die "no such libvirt domain: $node"
  printf '%s' "$uuid"
}

reset_type() {
  case "$1" in
    on)    printf 'On' ;;
    off)   printf 'ForceOff' ;;
    cycle) printf 'ForceRestart' ;;
    *)     die "power action must be on, off or cycle (got '$1')" ;;
  esac
}

boot_target() {
  case "$1" in
    pxe)  printf 'Pxe' ;;
    hd)   printf 'Hdd' ;;
    cd)   printf 'Cd' ;;
    http) printf 'UefiHttp' ;;
    *)    die "boot target must be pxe, hd, cd or http (got '$1')" ;;
  esac
}

cmd_list() {
  local ids
  ids="$(curl -fsS -H 'Accept: application/json' \
    "$REDFISH_ENDPOINT/redfish/v1/Systems/" \
    | python3 -c 'import json,sys;print("\n".join(m["@odata.id"] for m in json.load(sys.stdin)["Members"]))')"
  [[ -n "$ids" ]] || { warn "no systems exposed by $REDFISH_ENDPOINT"; return 0; }
  printf '%-38s %-10s %-10s %s\n' SYSTEM POWER STATE BOOT
  local path
  while read -r path; do
    [[ -n "$path" ]] || continue
    curl -fsS -H 'Accept: application/json' "$REDFISH_ENDPOINT$path" \
      | python3 -c '
import json,sys
d=json.load(sys.stdin)
b=d.get("Boot",{})
print("%-38s %-10s %-10s %s/%s" % (
    d.get("Id",""), d.get("PowerState",""), d.get("Status",{}).get("State",""),
    b.get("BootSourceOverrideTarget",""), b.get("BootSourceOverrideEnabled","")))'
  done <<< "$ids"
}

cmd_status() {
  local node="$1" id
  id="$(system_id "$node")"
  curl -fsS -H 'Accept: application/json' "$REDFISH_ENDPOINT/redfish/v1/Systems/$id" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
b=d.get("Boot",{})
print("System:     %s" % d.get("Id"))
print("PowerState: %s" % d.get("PowerState"))
print("Boot:       %s (%s)" % (b.get("BootSourceOverrideTarget"),
                               b.get("BootSourceOverrideEnabled")))
print("Allowable:  %s" % ", ".join(
    b.get("BootSourceOverrideTarget@Redfish.AllowableValues", [])))'
}

cmd_power() {
  local node="$1" action="$2" id rt
  id="$(system_id "$node")"
  rt="$(reset_type "$action")"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "{\"ResetType\":\"$rt\"}" \
    "$REDFISH_ENDPOINT/redfish/v1/Systems/$id/Actions/ComputerSystem.Reset")"
  [[ "$code" == 204 || "$code" == 200 ]] \
    || die "Reset $rt on $node failed: HTTP $code"
  changed "redfish $node power $action ($rt)"
}

cmd_boot() {
  local node="$1" target="$2" id bt
  id="$(system_id "$node")"
  bt="$(boot_target "$target")"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "{\"Boot\":{\"BootSourceOverrideTarget\":\"$bt\",\"BootSourceOverrideEnabled\":\"Continuous\"}}" \
    "$REDFISH_ENDPOINT/redfish/v1/Systems/$id")"
  [[ "$code" == 204 || "$code" == 200 ]] \
    || die "boot override $bt on $node failed: HTTP $code"
  # The override is only real if libvirt's persistent boot order changed.
  local order
  order="$("${VIRSH[@]}" dumpxml --inactive "$node" 2>/dev/null \
    | grep -E "<boot order=" | tr -d ' ' | tr '\n' ' ')"
  changed "redfish $node boot $target ($bt); libvirt boot order: ${order:-unchanged}"
}

[[ $# -ge 1 ]] || usage
case "$1" in
  list)   cmd_list ;;
  status) [[ $# -eq 2 ]] || usage; cmd_status "$2" ;;
  power)  [[ $# -eq 3 ]] || usage; cmd_power "$2" "$3" ;;
  boot)   [[ $# -eq 3 ]] || usage; cmd_boot "$2" "$3" ;;
  *)      usage ;;
esac
