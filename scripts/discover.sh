#!/usr/bin/env bash
#
# `make discover` — boot a node into the discovery image, wait for it to
# register itself in NetBox, and print the record and the console evidence.
#
# The node is switched to the discovery image and given the cluster-discovery
# runtime overlay for this boot, then both overrides are removed so a later
# boot is a provisioned image again. Only the image name and one overlay name
# are changed; the node keeps every system and runtime overlay the default
# profile gives it, so the discovery boot is a normal boot of a different
# image, not a special case.
#
#   make discover                 # node 1
#   make discover NODE=cn02       # one named node
#
# Nothing here knows how many nodes there are.

export LAB_SCRIPT_NAME=discover
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

NODE="${NODE:-$(node_name 1)}"
DISCOVERY_IMAGE="${WAREWULF_DISCOVERY_IMAGE_NAME:-discovery}"
DISCOVERY_OVERLAY="${DISCOVERY_OVERLAY:-cluster-discovery}"
DISCOVERY_TIMEOUT="${DISCOVERY_TIMEOUT:-420}"
NETBOX_LOCAL_URL="${NETBOX_LOCAL_URL:-http://127.0.0.1:8000}"
NETBOX_ENV_FILE="${NETBOX_ENV_FILE:-/etc/cluster-lab/netbox.env}"

VIRSH=(sudo virsh --connect "$LIBVIRT_URI")

# The NetBox API token is root-only in the NetBox environment file. Build it
# into the environment of the poller only; never print it, never put it on a
# command line.
netbox_token() {
  local key token
  sudo test -r "$NETBOX_ENV_FILE" \
    || die "missing $NETBOX_ENV_FILE — is NetBox up? (make up)"
  key="$(sudo sed -n 's/^SUPERUSER_API_KEY=//p' "$NETBOX_ENV_FILE" | head -1)"
  token="$(sudo sed -n 's/^SUPERUSER_API_TOKEN=//p' "$NETBOX_ENV_FILE" | head -1)"
  [[ -n "$key" && -n "$token" ]] || die "$NETBOX_ENV_FILE carries no API token"
  printf 'nbt_%s.%s' "$key" "$token"
}

node_defined() { "${VIRSH[@]}" dominfo "$1" >/dev/null 2>&1; }
node_running() { [[ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null || true)" == running ]]; }

# Boot the node from the network. sushy-emulator is the management path, so
# the same Redfish client the power/boot automation uses does the work.
power_into_pxe() {
  local node="$1"
  bash "$HERE/redfish.sh" boot "$node" pxe
  if node_running "$node"; then
    bash "$HERE/redfish.sh" power "$node" cycle
  else
    bash "$HERE/redfish.sh" power "$node" on
  fi
}

# Poll NetBox until the node's own record reports a completed discovery.
# Prints the device and its interfaces as JSON on success.
wait_for_record() {
  NETBOX_URL="$NETBOX_LOCAL_URL" \
  NETBOX_TOKEN="$(netbox_token)" \
  DISCOVERY_NODE="$NODE" \
  DISCOVERY_TIMEOUT="$DISCOVERY_TIMEOUT" \
  python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base = os.environ["NETBOX_URL"].rstrip("/")
token = os.environ["NETBOX_TOKEN"]
node = os.environ["DISCOVERY_NODE"]
deadline = time.time() + float(os.environ["DISCOVERY_TIMEOUT"])
headers = {"Authorization": f"Token {token}", "Accept": "application/json"}


def get(path):
    request = urllib.request.Request(base + path, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


last = "no response yet"
while time.time() < deadline:
    try:
        devices = get(f"/api/dcim/devices/?name={node}&limit=1").get("results", [])
    except (urllib.error.URLError, TimeoutError) as exc:
        last = f"{type(exc).__name__}: {exc}"
        time.sleep(5)
        continue

    if devices:
        device = devices[0]
        custom = device.get("custom_fields") or {}
        if custom.get("discovery_status") == "complete":
            interfaces = get(
                f"/api/dcim/interfaces/?device_id={device['id']}&limit=100"
            ).get("results", [])
            print(
                json.dumps(
                    {
                        "device": {
                            key: device.get(key)
                            for key in (
                                "id", "name", "serial", "device_type", "role",
                                "site", "primary_ip4", "custom_fields",
                            )
                        },
                        "interfaces": [
                            {
                                key: interface.get(key)
                                for key in ("id", "name", "mac_address", "mgmt_only")
                            }
                            for interface in interfaces
                        ],
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            sys.exit(0)

    time.sleep(5)

print(
    f"no completed NetBox discovery record for {node} within "
    f"{os.environ['DISCOVERY_TIMEOUT']}s (last NetBox error: {last})",
    file=sys.stderr,
)
sys.exit(1)
PY
}

node_defined "$NODE" || die "no such libvirt domain: $NODE (try 'make nodes-up')"

log "booting $NODE into image '$DISCOVERY_IMAGE' with overlay '$DISCOVERY_OVERLAY'"

# Node-level overrides. `--image` shadows the profile's image; the runtime
# overlay is appended to the profile's list, so the node keeps hosts,
# ssh.authorized_keys, the identity overlay and the wwclient fix. Both are
# removed in the restore step, whether this run succeeds or not.
sudo wwctl node set -y "$NODE" \
  --image "$DISCOVERY_IMAGE" \
  --runtime-overlays "$DISCOVERY_OVERLAY"

restore_node() {
  log "restoring $NODE to its provisioned image"
  sudo wwctl node set -y "$NODE" --image UNSET --runtime-overlays UNSET
}
trap restore_node EXIT

power_into_pxe "$NODE"

log "waiting up to ${DISCOVERY_TIMEOUT}s for the NetBox record (this is a full boot)"
if ! record="$(wait_for_record)"; then
  warn "no NetBox record for $NODE; console evidence follows"
  sudo tail -c 20000 "$LAB_VM_DIR/console/${NODE}.log" 2>/dev/null \
    | tr -d '\r' | grep -a 'cluster-discovery:' || true
  exit 1
fi

echo
echo "== NetBox record, as written by the node itself =="
printf '%s\n' "$record"

echo
echo "== discovery lines from the $NODE serial console =="
sudo grep -a 'cluster-discovery:' "$LAB_VM_DIR/console/${NODE}.log" 2>/dev/null \
  | tr -d '\r' | tail -n 40 || echo "(none captured)"
