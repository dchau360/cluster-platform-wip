#!/usr/bin/env bash
#
# Identity under a NIC swap — acceptance criterion #3.
#
#   make drill-nic-swap [NODE=<index>] [N=<n>]
#
# Swaps one node's virtual NIC MAC and proves the node's identity did not
# follow it. Three identities are recorded before and after:
#
#   * the node's hostname, read off its serial console and its DHCP lease
#   * the NetBox device the node is registered as, keyed by rack position
#   * the NetBox interface's MAC, which is the thing that *does* change
#
# The swap is the honest one: a real NIC replacement does not boot until the
# inventory knows the new address, so the new MAC is written to Warewulf (the
# mapping from address to node), to NetBox (the interface), and re-rendered
# into the dnsmasq reservations. What must not change is the name.

export LAB_SCRIPT_NAME=drill-nic-swap
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/boot-phases.sh
source "$HERE/lib/boot-phases.sh"
# shellcheck source=lib/node-reboot.sh
source "$HERE/lib/node-reboot.sh"
# shellcheck source=lib/netbox.sh
source "$HERE/lib/netbox.sh"
lab_load_env

INDEX="${NODE:-1}"
if [[ ! "$INDEX" =~ ^[0-9]+$ ]] || (( INDEX < 1 )); then
  die "NODE must be a positive integer"
fi
lab_name="$(node_name "$INDEX")"
# Two locally-administered addresses for the node. The drill swaps between
# them, so a repeat run is still a real change rather than a no-op. Nothing
# here is a real MAC.
base_mac="$(node_mac "$INDEX")"
alt_mac="$(printf '%s:00:ff:%02x' "${PROV_MAC_OUI:-52:54:00}" "$INDEX")"

counters_init
timing_init

nb_device() { # <field> (node index comes from NODE, above)
  netbox_get '/api/dcim/devices/?limit=200' | python3 -c '
import json, sys
index, field = int(sys.argv[1]), sys.argv[2]
for device in json.load(sys.stdin).get("results", []):
    if device.get("position") == index:
        print(device.get(field, ""))
        break
' "$INDEX" "$1"
}

nb_interface() { # <device-id> <field>
  netbox_get "/api/dcim/interfaces/?device_id=$1" | python3 -c '
import json, sys
field = sys.argv[1]
for interface in json.load(sys.stdin).get("results", []):
    if interface.get("name") == "provisioning":
        print(interface.get(field, ""))
        break
' "$2"
}

echo "=============================================================="
echo "pre-swap identity for $lab_name (index $INDEX)"
echo "=============================================================="
device_id="$(nb_device id)"
[[ -n "$device_id" ]] || die "no NetBox device at rack position $INDEX — run 'make converge' first"
pre_device="$(nb_device name)"
pre_position="$(nb_device position)"
pre_iface_id="$(nb_interface "$device_id" id)"
pre_iface_mac="$(nb_interface "$device_id" mac_address)"
pre_domain_mac="$(node_domain_mac "$lab_name")"
[[ -n "$pre_domain_mac" ]] || die "$lab_name is not defined — run 'make nodes-up' first"
if [[ "${pre_domain_mac,,}" == "${base_mac,,}" ]]; then
  new_mac="$alt_mac"
else
  new_mac="$base_mac"
fi
echo "domain MAC          : $pre_domain_mac"
echo "warewulf hwaddr     : $(sudo wwctl node list -a "$lab_name" 2>/dev/null | awk '/NetDevs\[default\]\.Hwaddr/{print $NF}')"
echo "netbox device       : $pre_device (position $pre_position, id $device_id)"
echo "netbox interface MAC: $pre_iface_mac"

echo
echo "=============================================================="
echo "swap: $pre_domain_mac -> $new_mac, re-register the same identity"
echo "=============================================================="
node_stop "$lab_name"

xml="$(mktemp)"
"${VIRSH[@]}" dumpxml --inactive "$lab_name" > "$xml"
sed -i "s/$pre_domain_mac/$new_mac/g" "$xml"
"${VIRSH[@]}" define "$xml" >/dev/null
rm -f "$xml"
changed "domain $lab_name MAC set to $new_mac"

sudo wwctl node set -y "$lab_name" --hwaddr "$new_mac" >/dev/null
changed "warewulf $lab_name hwaddr set to $new_mac"

if [[ -n "$pre_iface_id" ]]; then
  netbox_patch "/api/dcim/interfaces/$pre_iface_id/" "{\"mac_address\":\"$new_mac\"}" >/dev/null
  changed "netbox interface $pre_iface_id MAC set to $new_mac"
fi

# NetBox is the source of truth for the reservations, so re-render them and
# restart dnsmasq. The token is read from the root-only environment file
# inside this shell; it is never passed as an argument.
if sudo test -f /etc/cluster-lab/netbox.env; then
  sudo bash -c '
    # shellcheck disable=SC1091
    . /etc/cluster-lab/netbox.env
    export NETBOX_URL=http://127.0.0.1:8000
    export NETBOX_TOKEN="nbt_${SUPERUSER_API_KEY}.${SUPERUSER_API_TOKEN}"
    /opt/cluster-netbox/venv/bin/python /usr/local/sbin/render-netbox-dnsmasq
  '
  sudo systemctl restart lab-dnsmasq
  changed "dnsmasq reservations re-rendered from NetBox"
fi

lease_forget "$pre_domain_mac" "$new_mac"

phase_begin node-boot "$lab_name"
node_boot "$lab_name"
phase_end node-boot "$lab_name"
wait "$NODE_BOOT_WATCH_PID" || warn "$lab_name did not reach a login prompt in ${BOOT_PHASE_TIMEOUT:-300}s"

echo
echo "=============================================================="
echo "post-swap identity"
echo "=============================================================="
post_domain_mac="$(node_domain_mac "$lab_name")"
post_device="$(nb_device name)"
post_position="$(nb_device position)"
post_iface_mac="$(nb_interface "$device_id" mac_address)"
console_login="$(node_console_value "$lab_name" "$lab_name login:")"
lease_host="$(sudo awk -v m="$new_mac" 'tolower($2)==tolower(m){print $4}' \
  "$LAB_STATE_DIR/dnsmasq/leases" 2>/dev/null | tail -1)"
# Whichever source saw the hostname is enough; the console shows the login
# prompt, the lease line is what dnsmasq recorded from the DHCP client.
observed_host="${lease_host:-}"
[[ -n "$observed_host" ]] || observed_host="${console_login% login:}"

echo "domain MAC          : $post_domain_mac"
echo "netbox device       : $post_device (position $post_position)"
echo "netbox interface MAC: $post_iface_mac"
echo "console             : ${console_login:-<no login prompt seen>}"
echo "dhcp lease hostname : ${lease_host:-<none>}"
echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"

fails=0
check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS %s: %s\n' "$1" "$3"
  else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

check "the MAC changed"                 "${new_mac,,}"      "${post_domain_mac,,}"
check "NetBox recorded the new MAC"     "${new_mac,,}"      "${post_iface_mac,,}"
check "the NetBox device kept its name" "$pre_device"       "$post_device"
check "the hostname did not change"     "$lab_name"         "$observed_host"
check "the node still booted as itself" "$lab_name login:"  "$console_login"

echo
if (( fails > 0 )); then
  die "$fails identity check(s) failed"
fi
printf '%sNIC SWAP OK%s — MAC changed, %s kept its name in Warewulf, on the console and in NetBox\n' \
  "$_C_GRN" "$_C_RST" "$lab_name"
