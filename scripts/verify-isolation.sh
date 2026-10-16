#!/usr/bin/env bash
#
# Prove the provisioning segment cannot reach the home LAN.
#
# Three tests, strongest last:
#
#   A. Route dump. The only route that names the bridge is its own subnet.
#   B. Host-side ping bound to the bridge. The kernel has no route to the
#      home LAN out of that interface, so the attempt fails at route lookup.
#   C. Node-side ping. A network namespace is attached to the bridge and set
#      up the way a provisioned node would be: an address from the DHCP pool
#      and a default route via the segment gateway. From there the home LAN
#      must still be unreachable. This is the test that matters, because it
#      is the only one that answers "what can a node on this segment do".
#
# Needs LAB_LAN_CIDR and LAB_LAN_PROBE_IP in lab/local.env. Those are host
# values, so they are never in a tracked file.

export LAB_SCRIPT_NAME=verify-isolation
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env
lab_require_env LAB_LAN_CIDR LAB_LAN_PROBE_IP

NS=cluster-lab-probe
VETH_HOST=veth-probe
VETH_NS=veth-probe-ns
PROBE_IP="${PROV_DHCP_END}"

fails=0
bad()  { fails=$((fails + 1)); printf 'FAIL %s\n' "$*"; }
good() { printf 'PASS %s\n' "$*"; }

ip link show "$PROV_BRIDGE" >/dev/null 2>&1 \
  || die "$PROV_BRIDGE does not exist — run 'make up' first"

cleanup() {
  sudo ip netns delete "$NS" 2>/dev/null || true
  sudo ip link delete "$VETH_HOST" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

echo "=============================================================="
echo "0. positive control: the home LAN IS reachable from this host"
echo "=============================================================="
# Without this, "unreachable" could just mean the probe address is down,
# and every test below would pass for the wrong reason.
echo "\$ ping -c 2 -W 2 <LAB_LAN_PROBE_IP>        # default route, not the segment"
if ping -c 2 -W 2 "$LAB_LAN_PROBE_IP" >/dev/null 2>&1; then
  good "the probe address answers over the default route, so the tests below mean something"
else
  bad "the probe address does not answer at all — pick a live LAB_LAN_PROBE_IP"
fi

echo
echo "=============================================================="
echo "A. routes that name $PROV_BRIDGE"
echo "=============================================================="
ip route show dev "$PROV_BRIDGE"
echo "--- full routing table ---"
ip route show
echo "--- all tables ---"
ip route show table all | grep -F "$PROV_BRIDGE" || echo "(no entries)"

if ip route show table all | grep -F "$PROV_BRIDGE" | grep -vF "$PROV_CIDR" \
   | grep -qvE 'local|broadcast|proto kernel'; then
  bad "a route other than $PROV_CIDR names $PROV_BRIDGE"
else
  good "the only forwarding route on $PROV_BRIDGE is $PROV_CIDR"
fi

echo
echo "=============================================================="
echo "B. host-side ping of the home LAN, bound to $PROV_BRIDGE"
echo "=============================================================="
echo "\$ ping -c 2 -W 2 -I $PROV_BRIDGE <LAB_LAN_PROBE_IP>"
if ping -c 2 -W 2 -I "$PROV_BRIDGE" "$LAB_LAN_PROBE_IP" 2>&1 | sed "s#$LAB_LAN_PROBE_IP#<LAB_LAN_PROBE_IP>#g"; then
  bad "home LAN answered a ping bound to $PROV_BRIDGE"
else
  good "home LAN unreachable from $PROV_BRIDGE"
fi

echo
echo "=============================================================="
echo "C. node-side ping from a namespace on the segment"
echo "=============================================================="
sudo ip netns add "$NS"
sudo ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
sudo ip link set "$VETH_NS" netns "$NS"
sudo ip link set "$VETH_HOST" master "$PROV_BRIDGE" up
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set "$VETH_NS" up
sudo ip netns exec "$NS" ip addr add "$PROBE_IP/$PROV_PREFIX" dev "$VETH_NS"
# Set up exactly as a provisioned node would be, default route included.
sudo ip netns exec "$NS" ip route add default via "$PROV_GW"

echo "--- namespace config (stand-in for a provisioned node) ---"
sudo ip netns exec "$NS" ip -br addr show "$VETH_NS"
sudo ip netns exec "$NS" ip route show

echo
echo "\$ ip netns exec $NS ping -c 2 -W 2 $PROV_GW        # segment gateway"
if sudo ip netns exec "$NS" ping -c 2 -W 2 "$PROV_GW" >/dev/null 2>&1; then
  good "segment gateway $PROV_GW is reachable — the segment carries traffic"
else
  bad "segment gateway $PROV_GW is NOT reachable — the segment is broken"
fi

echo
echo "\$ ip netns exec $NS ping -c 2 -W 2 <LAB_LAN_PROBE_IP>"
if sudo ip netns exec "$NS" ping -c 2 -W 2 "$LAB_LAN_PROBE_IP" 2>&1 \
     | sed "s#$LAB_LAN_PROBE_IP#<LAB_LAN_PROBE_IP>#g"; then
  bad "a node on the segment reached the home LAN"
else
  good "a node on the segment cannot reach the home LAN"
fi

echo
echo "=============================================================="
echo "D. the enforcement is installed"
echo "=============================================================="
# Tests A to C show that nothing CAN get out right now. This shows that
# something would stop it if a route appeared. The nftables table is the
# enforcement; the per-interface knob is only advisory, because Docker
# writes net.ipv4.conf.all.forwarding=1 and that sets every interface.
if sudo nft list table inet cluster_lab >/dev/null 2>&1; then
  good "nftables table inet cluster_lab is installed"
else
  bad "nftables table inet cluster_lab is MISSING — nothing would stop a new route"
fi

# The counters normally stay at zero, and that is the correct result: with
# no route out of the bridge, the packets never reach the forward hook.
echo "--- nftables backstop (counters stay 0 while no route exists to drop) ---"
sudo nft list table inet cluster_lab 2>/dev/null || echo "(table absent)"

fwd="$(cat "/proc/sys/net/ipv4/conf/$PROV_BRIDGE/forwarding" 2>/dev/null || echo '?')"
echo "--- advisory: net.ipv4.conf.$PROV_BRIDGE.forwarding = $fwd ---"
if [[ "$fwd" != "0" ]] && [[ "${NODE_INTERNET_ACCESS:-no}" =~ ^(yes|true|1)$ || "${LAB_LAN_ACCESS:-no}" =~ ^(yes|true|1)$ ]]; then
  echo "forwarding is on because lab/local.env enables NODE_INTERNET_ACCESS or"
  echo "LAB_LAN_ACCESS. The table above allows only that traffic and still drops"
  echo "new connections from the segment to the home LAN and other private ranges."
elif [[ "$fwd" != "0" ]]; then
  warn "forwarding is on for $PROV_BRIDGE. Something wrote net.ipv4.conf.all.forwarding
     after 'make up' — Docker does this when it restarts. Not a failure: the
     nftables drop above still holds. 'make up' sets it back."
fi

echo
echo "=============================================================="
if (( fails > 0 )); then
  echo "RESULT: $fails isolation test(s) FAILED"
  exit 1
fi
echo "RESULT: isolation verified"
