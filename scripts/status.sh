#!/usr/bin/env bash
#
# One screen that answers "is the lab up, and what is on the segment".

export LAB_SCRIPT_NAME=status
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

echo "== units"
for unit in lab.target lab-net.service lab-dnsmasq.service libvirtd.socket docker.service; do
  printf '%-22s %-10s %s\n' "$unit" \
    "$(systemctl is-enabled "$unit" 2>/dev/null || echo -)" \
    "$(systemctl is-active "$unit" 2>/dev/null || echo -)"
done

echo
echo "== segment"
if ip link show "$PROV_BRIDGE" >/dev/null 2>&1; then
  ip -br addr show "$PROV_BRIDGE"
  ports="$(find "/sys/class/net/$PROV_BRIDGE/brif" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
  echo "ports: ${ports:-none}"
  echo "routes:"; ip route show dev "$PROV_BRIDGE" | sed 's/^/  /'
else
  echo "$PROV_BRIDGE absent"
fi

echo
echo "== isolation rules"
sudo nft list table inet cluster_lab 2>/dev/null | sed 's/^/  /' || echo "  (table absent)"

echo
echo "== nodes (NODE_COUNT=$NODE_COUNT)"
sudo virsh --connect "$LIBVIRT_URI" list --all 2>/dev/null || echo "  libvirt unavailable"

echo
echo "== dhcp leases"
sudo cat "$LAB_STATE_DIR/dnsmasq/leases" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

echo
echo "== timing runs"
find "$LAB_TIMING_DIR" -maxdepth 1 -name '*.ndjson' -printf '%T@\t%p\n' 2>/dev/null \
  | sort -rn | head -5 | cut -f2- | sed 's/^/  /' | grep . || echo "  (none)"
