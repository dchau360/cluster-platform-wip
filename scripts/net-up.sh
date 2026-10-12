#!/usr/bin/env bash
#
# Bring up the isolated provisioning segment.
#
# The segment is a Linux bridge with NO uplink port. Nothing is ever enslaved
# to it except node taps, so there is no path to the home LAN by construction.
# Three further measures make that an enforced property rather than a habit:
#
#   1. IP forwarding is switched off on the bridge interface.
#   2. An nftables table of our own drops every forwarded packet that enters
#      or leaves the bridge. It is a separate table from the one Docker
#      manages, so the two never fight, and a drop in any table is final.
#   3. dnsmasq binds only to the bridge address. DHCP and TFTP are never
#      offered on an interface that can reach the home LAN.

export LAB_SCRIPT_NAME=net-up
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

NFT_TABLE=cluster_lab

# --- bridge ----------------------------------------------------------------

if ip link show "$PROV_BRIDGE" >/dev/null 2>&1; then
  ok "bridge $PROV_BRIDGE"
else
  sudo ip link add name "$PROV_BRIDGE" type bridge
  changed "bridge $PROV_BRIDGE created"
fi

# No STP, no forwarding delay: a one-hop lab segment gains nothing from it
# and a 15 s delay would show up in every measured PXE phase.
sudo ip link set "$PROV_BRIDGE" type bridge stp_state 0 forward_delay 0

if ip -4 addr show dev "$PROV_BRIDGE" | grep -qF "$PROV_GW/$PROV_PREFIX"; then
  ok "address $PROV_GW/$PROV_PREFIX on $PROV_BRIDGE"
else
  sudo ip addr flush dev "$PROV_BRIDGE"
  sudo ip addr add "$PROV_GW/$PROV_PREFIX" dev "$PROV_BRIDGE"
  changed "address $PROV_GW/$PROV_PREFIX added to $PROV_BRIDGE"
fi

# A bridge with no ports has no carrier, so its OPERATIONAL state stays
# DOWN however many times it is brought up. Test the administrative flag
# instead: IFF_UP, bit 0 of the interface flags. Checking operstate here
# would make `make up` report a change on every single run.
if (( $(cat "/sys/class/net/$PROV_BRIDGE/flags") & 0x1 )); then
  ok "$PROV_BRIDGE is administratively up"
else
  sudo ip link set "$PROV_BRIDGE" up
  changed "$PROV_BRIDGE brought up"
fi

# --- isolation -------------------------------------------------------------

for knob in forwarding rp_filter; do
  want=0; [[ "$knob" == rp_filter ]] && want=1
  path="/proc/sys/net/ipv4/conf/$PROV_BRIDGE/$knob"
  [[ -w "$path" ]] || [[ -e "$path" ]] || continue
  if [[ "$(cat "$path" 2>/dev/null || echo x)" == "$want" ]]; then
    ok "sysctl $PROV_BRIDGE.$knob=$want"
  else
    echo "$want" | sudo tee "$path" >/dev/null
    changed "sysctl $PROV_BRIDGE.$knob=$want"
  fi
done

read -r -d '' NFT_RULESET <<EOF || true
table inet $NFT_TABLE {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$PROV_BRIDGE" oifname != "$PROV_BRIDGE" counter drop
    oifname "$PROV_BRIDGE" iifname != "$PROV_BRIDGE" counter drop
  }
}
EOF

current="$(sudo nft -s list table inet "$NFT_TABLE" 2>/dev/null || true)"
if [[ -n "$current" ]] \
   && [[ "$(printf '%s' "$current" | grep -c 'counter drop')" == "2" ]] \
   && printf '%s' "$current" | grep -qF "iifname \"$PROV_BRIDGE\""; then
  ok "nftables table inet $NFT_TABLE"
else
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  printf '%s\n' "$NFT_RULESET" | sudo nft -f -
  changed "nftables table inet $NFT_TABLE installed"
fi

# Node to node. Docker (NetBox) loads br_netfilter, so frames bridged between
# two node taps traverse iptables FORWARD, whose policy Docker sets to drop.
# Head-to-node traffic is not forwarded and never notices; node-to-node is
# silently dropped, which breaks every multi-node Slurm step. Accept traffic
# that both enters and leaves the bridge, in DOCKER-USER (the chain Docker
# leaves alone) when it exists. Traffic leaving the segment is still dropped
# by the table above.
if [[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)" == 1 ]]; then
  chain=FORWARD
  sudo iptables -n -L DOCKER-USER >/dev/null 2>&1 && chain=DOCKER-USER
  rule=(-i "$PROV_BRIDGE" -o "$PROV_BRIDGE" -m comment --comment cluster-lab-segment -j ACCEPT)
  if sudo iptables -C "$chain" "${rule[@]}" 2>/dev/null; then
    ok "iptables $chain accepts traffic within $PROV_BRIDGE"
  else
    sudo iptables -I "$chain" 1 "${rule[@]}"
    changed "iptables $chain accepts traffic within $PROV_BRIDGE"
  fi
else
  ok "bridge netfilter off; traffic within $PROV_BRIDGE is not filtered"
fi

# --- dnsmasq configuration -------------------------------------------------

ensure_dir "$LAB_STATE_DIR/dnsmasq" 0755
ensure_dir "$LAB_TFTP_DIR"          0755
# dnsmasq refuses to serve a TFTP root that does not exist, so create
# Warewulf's tree even before the role has filled it with boot programmes.
ensure_dir "$WAREWULF_TFTP_ROOT"    0755

# NetBox owns reservations. Keep an empty generated file available during
# first boot; the head-node play replaces it after NetBox is seeded.
if [[ ! -e "$LAB_STATE_DIR/dnsmasq/netbox-hosts.conf" ]]; then
  sudo install -m 0644 /dev/null "$LAB_STATE_DIR/dnsmasq/netbox-hosts.conf"
  changed "empty NetBox dnsmasq reservation file created"
fi

ensure_file_content "$LAB_STATE_DIR/dnsmasq/lab.conf" 0644 <<EOF
# Generated by scripts/net-up.sh. Do not edit by hand.
#
# Bound to $PROV_BRIDGE only. Never to an interface that can reach the
# home LAN. bind-interfaces makes that a hard bind rather than a filter.
interface=$PROV_BRIDGE
bind-interfaces
except-interface=lo
listen-address=$PROV_GW
no-hosts
no-resolv
domain=$PROV_DOMAIN
local=/$PROV_DOMAIN/
expand-hosts

dhcp-authoritative
dhcp-range=$PROV_DHCP_START,$PROV_DHCP_END,$PROV_DHCP_LEASE
dhcp-option=option:router,$PROV_GW
dhcp-option=option:dns-server,$PROV_GW
dhcp-hostsfile=$LAB_STATE_DIR/dnsmasq/netbox-hosts.conf
dhcp-leasefile=$LAB_STATE_DIR/dnsmasq/leases

# Warewulf PXE chain. DHCP still comes from NetBox via netbox-hosts.conf;
# these options only add the boot programme. A UEFI client is handed iPXE
# over TFTP, and iPXE is handed its script by warewulfd over HTTP. This
# mirrors Warewulf's own dnsmasq template, minus the DHCP server it would
# otherwise start — the lab's dnsmasq is the only one on the segment.
dhcp-match=set:x86PC,option:client-arch,7
dhcp-match=set:x86PC,option:client-arch,9
dhcp-match=set:iPXE,77,"iPXE"
dhcp-userclass=set:iPXE,iPXE
dhcp-boot=tag:x86PC,"/warewulf/snponly.efi"
dhcp-boot=tag:iPXE,"http://$PROV_GW:$WAREWULF_HTTP_PORT/ipxe/\${mac:hexhyp}?assetkey=\${asset}&uuid=\${uuid}"
dhcp-no-override

enable-tftp
tftp-root=$WAREWULF_TFTP_ROOT
tftp-no-blocksize

log-dhcp
log-facility=$LAB_STATE_DIR/dnsmasq/dnsmasq.log
pid-file=$LAB_RUN_DIR/dnsmasq.pid
EOF

log "segment $PROV_CIDR on $PROV_BRIDGE, ${NODE_COUNT} node reservation(s)"
