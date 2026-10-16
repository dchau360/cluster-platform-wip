#!/usr/bin/env bash
#
# Bring up the isolated provisioning segment.
#
# Creates the subnet as well as the bridge: PROV_SUBNET in lab/local.env may
# name any private network nothing on this host uses yet. The head node takes
# the first address on it as the gateway, which is the only link between the
# segment and the host.
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

# --- subnet ----------------------------------------------------------------

# The segment's subnet is PROV_SUBNET from lab/local.env, or the definition's
# default. It only has to be unused: this script creates it. So refuse one
# the host already reaches some other way — a route on another interface, a
# Docker network, or the home LAN — because the bridge would then shadow that
# network, or be shadowed by it, and the failure would look like a dead node.
in_use() {
  ip -4 -o route show | awk -v bridge="$PROV_BRIDGE" '
    $1 != "default" {
      for (i = 2; i < NF; i++) if ($i == "dev") dev = $(i + 1)
      if (dev != bridge) print dev, $1
    }'
  [[ -z "${LAB_LAN_CIDR:-}" ]] || echo "home-LAN(LAB_LAN_CIDR) $LAB_LAN_CIDR"
  if command -v docker >/dev/null 2>&1; then
    local networks=()
    mapfile -t networks < <(sudo docker network ls -q 2>/dev/null || true)
    (( ${#networks[@]} == 0 )) || sudo docker network inspect \
      -f '{{range .IPAM.Config}}docker:{{$.Name}} {{.Subnet}}{{"\n"}}{{end}}' \
      "${networks[@]}" 2>/dev/null || true
  fi
}
if clashes="$(in_use | python3 "$REPO_ROOT/netbox/address_plan.py" conflicts)"; then
  ok "subnet $PROV_CIDR is not used anywhere else on this host"
else
  die "subnet $PROV_CIDR is already in use here: $(printf '%s' "$clashes" | paste -sd, - | sed 's/,/, /g'). Set PROV_SUBNET in lab/local.env to an unused private /${PROV_PREFIX} or larger."
fi

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

# --- routed access ---------------------------------------------------------

# These are independent opt-ins. LAN access allows new connections from the
# home LAN into the cluster. Node internet access allows new connections from
# the provisioning segment out through the head node, with source NAT. Neither
# option exposes DHCP or TFTP because dnsmasq remains bound to PROV_BRIDGE.
bool_setting() {
  local name="$1" value="${!1:-}" default="$2"
  case "$value" in
    yes|true|1) printf yes ;;
    no|false|0) printf no ;;
    '') printf '%s' "$default" ;;
    *) die "$name must be yes or no, not '$value'" ;;
  esac
}
lan_access="$(bool_setting LAB_LAN_ACCESS no)"
node_internet="$(bool_setting NODE_INTERNET_ACCESS no)"

lan_clients=()
if [[ "$lan_access" == yes ]]; then
  [[ -n "${LAB_LAN_CIDR:-}" ]] || die "LAB_LAN_ACCESS=yes needs LAB_LAN_CIDR in lab/local.env"
  lan_clients=("$LAB_LAN_CIDR")
  wsl_gw="$(ip -4 route show default | awk '{ print $3; exit }')"
  [[ -z "$wsl_gw" ]] || lan_clients+=("$wsl_gw/32")
fi

want_forwarding=0
[[ "$lan_access" == yes || "$node_internet" == yes ]] && want_forwarding=1
for knob in forwarding rp_filter; do
  want=$want_forwarding; [[ "$knob" == rp_filter ]] && want=1
  path="/proc/sys/net/ipv4/conf/$PROV_BRIDGE/$knob"
  [[ -w "$path" ]] || [[ -e "$path" ]] || continue
  if [[ "$(cat "$path" 2>/dev/null || echo x)" == "$want" ]]; then
    ok "sysctl $PROV_BRIDGE.$knob=$want"
  else
    echo "$want" | sudo tee "$path" >/dev/null
    changed "sysctl $PROV_BRIDGE.$knob=$want"
  fi
done

lan_rules=""
lan_forward=""
if [[ "$lan_access" == yes ]]; then
  clients="$(printf '%s, ' "${lan_clients[@]}")"; clients="${clients%, }"
  read -r -d '' lan_rules <<EOF || true
  set lan_clients {
    type ipv4_addr; flags interval;
    elements = { $clients }
  }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname != "$PROV_BRIDGE" ip saddr @lan_clients ip daddr $PROV_CIDR tcp dport 22 accept
    iifname != "$PROV_BRIDGE" ip saddr @lan_clients ip daddr $PROV_CIDR meta l4proto icmp accept
    iifname != "$PROV_BRIDGE" ip saddr @lan_clients ip daddr $PROV_CIDR counter drop
  }
EOF
  lan_forward="
    oifname \"$PROV_BRIDGE\" iifname != \"$PROV_BRIDGE\" ip saddr @lan_clients counter accept
    iifname \"$PROV_BRIDGE\" oifname != \"$PROV_BRIDGE\" ct state established,related counter accept"
fi

# Internet means public addresses only. A node may not open connections to
# the home LAN, Windows, Docker or any other private range, so egress cannot
# become a path around the isolation that keeps the lab off the home network.
# Replies to LAN-initiated connections are established traffic and pass above.
internet_forward=""
if [[ "$node_internet" == yes ]]; then
  internet_forward="
    iifname \"$PROV_BRIDGE\" oifname != \"$PROV_BRIDGE\" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } ct state new counter drop
    iifname \"$PROV_BRIDGE\" oifname != \"$PROV_BRIDGE\" ip saddr $PROV_CIDR counter accept
    oifname \"$PROV_BRIDGE\" iifname != \"$PROV_BRIDGE\" ip daddr $PROV_CIDR ct state established,related counter accept"
fi

read -r -d '' NFT_BODY <<EOF || true
$lan_rules
  chain forward {
    type filter hook forward priority -10; policy accept;
$lan_forward$internet_forward
    iifname "$PROV_BRIDGE" oifname != "$PROV_BRIDGE" counter drop
    oifname "$PROV_BRIDGE" iifname != "$PROV_BRIDGE" counter drop
  }
EOF

digest="$(printf '%s' "$NFT_BODY" | sha256sum | cut -c1-16)"
current="$(sudo nft list table inet "$NFT_TABLE" 2>/dev/null || true)"
if [[ "$current" == *"cluster-lab $digest"* ]]; then
  ok "nftables table inet $NFT_TABLE (LAN: $lan_access, internet: $node_internet)"
else
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  printf 'table inet %s {\n  comment "cluster-lab %s"\n%s\n}\n' "$NFT_TABLE" "$digest" "$NFT_BODY" | sudo nft -f -
  changed "nftables table inet $NFT_TABLE installed (LAN: $lan_access, internet: $node_internet)"
fi

# NAT is separate from filtering. Masquerading lets replies return through the
# head node without teaching upstream routers about the provisioning subnet.
NAT_TABLE=cluster_lab_nat
if [[ "$node_internet" == yes ]]; then
  read -r -d '' NAT_RULESET <<EOF || true
table ip $NAT_TABLE {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$PROV_BRIDGE" oifname != "$PROV_BRIDGE" ip saddr $PROV_CIDR masquerade
  }
}
EOF
  current_nat="$(sudo nft -s list table ip "$NAT_TABLE" 2>/dev/null || true)"
  if [[ "$current_nat" == *"ip saddr $PROV_CIDR masquerade"* ]]; then
    ok "nftables NAT for node internet access"
  else
    sudo nft delete table ip "$NAT_TABLE" 2>/dev/null || true
    printf '%s\n' "$NAT_RULESET" | sudo nft -f -
    changed "nftables NAT installed for node internet access"
  fi
elif sudo nft list table ip "$NAT_TABLE" >/dev/null 2>&1; then
  sudo nft delete table ip "$NAT_TABLE"
  changed "nftables NAT removed (node internet access: no)"
else
  ok "nftables NAT absent (node internet access: no)"
fi

# Node to node. Docker (NetBox) loads br_netfilter, so frames bridged between
# two node taps traverse iptables FORWARD, whose policy Docker sets to drop.
# Head-to-node traffic is not forwarded and never notices; node-to-node is
# silently dropped, which breaks every multi-node Slurm step. Accept traffic
# that both enters and leaves the bridge, in DOCKER-USER (the chain Docker
# leaves alone) when it exists. Traffic leaving the segment is still dropped
# by the table above.
chain=FORWARD
sudo iptables -n -L DOCKER-USER >/dev/null 2>&1 && chain=DOCKER-USER
if [[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)" == 1 ]]; then
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

# Docker's iptables policy also needs explicit routed accepts. Keep these
# comment-tagged so changing either flag removes stale rules idempotently.
want_routed=()
if [[ "$lan_access" == yes ]]; then
  for client in "${lan_clients[@]}"; do
    want_routed+=("-A $chain -s $client -o $PROV_BRIDGE -m comment --comment cluster-lab-routed -j ACCEPT")
  done
fi
if [[ "$lan_access" == yes || "$node_internet" == yes ]]; then
  want_routed+=("-A $chain -o $PROV_BRIDGE -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment cluster-lab-routed -j ACCEPT")
fi
if [[ "$node_internet" == yes ]]; then
  want_routed+=("-A $chain -s $PROV_CIDR -i $PROV_BRIDGE -m comment --comment cluster-lab-routed -j ACCEPT")
fi
have_routed="$(sudo iptables -S "$chain" | grep -F -- '--comment cluster-lab-routed' | sort || true)"
want_routed_text="$( (( ${#want_routed[@]} == 0 )) || printf '%s\n' "${want_routed[@]}" | sort)"
if [[ "$want_routed_text" == "$have_routed" ]]; then
  ok "iptables $chain routed rules match"
else
  while read -r spec; do
    [[ -n "$spec" ]] || continue
    # shellcheck disable=SC2086
    sudo iptables ${spec/#-A/-D}
  done <<<"$have_routed"
  for spec in "${want_routed[@]}"; do
    # shellcheck disable=SC2086
    sudo iptables ${spec/#-A $chain/-I $chain 1}
  done
  changed "iptables $chain routed rules set"
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

# Node names on the head node. WSL rewrites /etc/hosts every time the
# distribution starts, which drops the block the dnsmasq role rendered from
# NetBox. Put it back from that render; NetBox itself may not be up yet.
if [[ -x /usr/local/sbin/render-netbox-dnsmasq ]]; then
  if [[ "$(sudo DNSMASQ_NETBOX_HOSTS_OUTPUT="$LAB_STATE_DIR/dnsmasq/netbox-hosts" \
          python3 /usr/local/sbin/render-netbox-dnsmasq --etc-hosts)" == changed ]]; then
    changed "node names restored to /etc/hosts"
  else
    ok "node names in /etc/hosts"
  fi
fi

# DNS for names outside the lab. With node internet access off, dnsmasq
# answers only for $PROV_DOMAIN and forwards nothing. With it on, dnsmasq
# forwards to the head node's own resolvers (WSL's DNS proxy, usually),
# or to NODE_DNS_UPSTREAM when set. Loopback stubs such as systemd-resolved's
# 127.0.0.53 are skipped in favour of the servers behind them.
dns_upstream=""
if [[ "$node_internet" == yes ]]; then
  if [[ -n "${NODE_DNS_UPSTREAM:-}" ]]; then
    upstreams="${NODE_DNS_UPSTREAM//,/ }"
  else
    resolv=/etc/resolv.conf
    [[ -r /run/systemd/resolve/resolv.conf ]] && resolv=/run/systemd/resolve/resolv.conf
    upstreams="$(awk '$1 == "nameserver" && $2 !~ /^127\./ && $2 !~ /:/ { print $2 }' "$resolv" | xargs)"
  fi
  [[ -n "$upstreams" ]] || die "NODE_INTERNET_ACCESS=yes but no upstream DNS server found; set NODE_DNS_UPSTREAM in lab/local.env"
  for server in $upstreams; do dns_upstream+="server=$server"$'\n'; done
fi

dnsmasq_conf_before="$(sudo sha256sum "$LAB_STATE_DIR/dnsmasq/lab.conf" 2>/dev/null || true)"
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
${dns_upstream}domain=$PROV_DOMAIN
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

# A running dnsmasq only reads its config at start. Restart it when the
# config changed, so flipping NODE_INTERNET_ACCESS takes effect on make up.
if [[ "$(sudo sha256sum "$LAB_STATE_DIR/dnsmasq/lab.conf")" != "$dnsmasq_conf_before" ]] \
   && systemctl is-active --quiet lab-dnsmasq.service; then
  sudo systemctl restart lab-dnsmasq.service
  changed "lab-dnsmasq restarted for the new config"
fi

log "segment $PROV_CIDR on $PROV_BRIDGE, ${NODE_COUNT} node reservation(s)"
