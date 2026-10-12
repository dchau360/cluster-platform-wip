#!/usr/bin/env bash
#
# Tear the provisioning segment down. Leaves state files in place so a
# following `make up` is fast and the timing history survives.

export LAB_SCRIPT_NAME=net-down
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

NFT_TABLE=cluster_lab

if sudo nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
  sudo nft delete table inet "$NFT_TABLE"
  changed "nftables table inet $NFT_TABLE removed"
else
  ok "nftables table inet $NFT_TABLE absent"
fi

for chain in DOCKER-USER FORWARD; do
  rule=(-i "$PROV_BRIDGE" -o "$PROV_BRIDGE" -m comment --comment cluster-lab-segment -j ACCEPT)
  while sudo iptables -C "$chain" "${rule[@]}" 2>/dev/null; do
    sudo iptables -D "$chain" "${rule[@]}"
    changed "iptables $chain rule for $PROV_BRIDGE removed"
  done
done

if ip link show "$PROV_BRIDGE" >/dev/null 2>&1; then
  sudo ip link set "$PROV_BRIDGE" down
  sudo ip link delete "$PROV_BRIDGE" type bridge
  changed "bridge $PROV_BRIDGE removed"
else
  ok "bridge $PROV_BRIDGE absent"
fi
