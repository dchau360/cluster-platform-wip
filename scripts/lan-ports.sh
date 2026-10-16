#!/usr/bin/env bash
#
# Reach the cluster from the home LAN through port forwards on the Windows
# host. LAN_PORT_FORWARDS=yes in lab/local.env turns it on.
#
# A route to the cluster subnet through Windows cannot work: WSL's NAT
# rewrites the source address of the cluster's replies (README part 2).
# Port forwards do not route, they relay. Every hop below accepts a
# connection and opens a new one, so no reply ever crosses the NAT:
#
#   LAN device  -> Windows :<port>                 netsh portproxy, Windows Firewall
#               -> Windows 127.0.0.1:<port+30000>   WSL localhost forwarding
#               -> head node 127.0.0.1:<port+30000> systemd-socket-proxyd (this script)
#               -> the target: a node's sshd, NetBox, Prometheus, ...
#
# The only address Windows ever holds is 127.0.0.1, so nothing on Windows goes
# stale when WSL picks a new address at boot, and nothing needs refreshing.
# The relays here listen on loopback only. Windows Firewall, scoped to
# LAB_LAN_CIDR, decides who may connect.
#
# This script owns the head-node half and prints the command for the Windows
# half, which needs an elevated PowerShell and so cannot run from here.
# With LAN_PORT_FORWARDS=no it removes every relay it installed.

export LAB_SCRIPT_NAME=lan-ports
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

UNIT_DIR=/etc/systemd/system
PREFIX=lab-lan-
# Head-node relay port = LAN port + OFFSET. The LAN ports cannot be reused as
# they are: NetBox already holds 127.0.0.1:8000 on the head node, and WSL
# mirrors that onto Windows 127.0.0.1:8000.
OFFSET=30000
PROXYD=/usr/lib/systemd/systemd-socket-proxyd

case "${LAN_PORT_FORWARDS:-no}" in
  yes|true|1) enabled=yes ;;
  no|false|0|'') enabled=no ;;
  *) die "LAN_PORT_FORWARDS must be yes or no, not '$LAN_PORT_FORWARDS'" ;;
esac
ssh_base="${LAN_SSH_PORT_BASE:-2200}"

# name  LAN-port  target
port_map() {
  echo "head-ssh $ssh_base 127.0.0.1:22"
  local i
  for i in $(lab_node_indexes); do
    echo "$(node_name "$i")-ssh $(( ssh_base + i )) $(node_ip "$i"):22"
  done
  echo "netbox 8000 127.0.0.1:8000"
  echo "prometheus 9090 127.0.0.1:9090"
  echo "alertmanager 9093 127.0.0.1:9093"
}

want=()
if [[ "$enabled" == yes ]]; then
  [[ -x "$PROXYD" ]] || die "$PROXYD not found; it ships with systemd"
  [[ "$ssh_base" =~ ^[0-9]+$ ]] || die "LAN_SSH_PORT_BASE must be a port number, not '$ssh_base'"
  map="$(port_map)"
  dupes="$(awk '{print $2}' <<<"$map" | sort | uniq -d | paste -sd, -)"
  [[ -z "$dupes" ]] || die "LAN port(s) $dupes are mapped twice; move LAN_SSH_PORT_BASE away from 8000, 9090 and 9093"
  while read -r name port target; do
    (( port >= 1024 && port + OFFSET <= 65535 )) || die "LAN port $port for $name is out of range 1024-$(( 65535 - OFFSET ))"
    want+=("$name")
    ensure_file_content "$UNIT_DIR/$PREFIX$name.socket" 0644 <<UNIT
# Written by scripts/lan-ports.sh. Do not edit; set LAN_PORT_FORWARDS and run \`make up\`.
[Unit]
Description=Cluster lab: LAN port $port -> $target ($name)
PartOf=lab.target

[Socket]
ListenStream=127.0.0.1:$(( port + OFFSET ))

[Install]
WantedBy=lab.target
UNIT
    ensure_file_content "$UNIT_DIR/$PREFIX$name.service" 0644 <<UNIT
# Written by scripts/lan-ports.sh. Do not edit; set LAN_PORT_FORWARDS and run \`make up\`.
[Unit]
Description=Cluster lab: relay LAN port $port to $target ($name)
Requires=$PREFIX$name.socket
After=$PREFIX$name.socket

[Service]
ExecStart=$PROXYD $target
DynamicUser=yes
PrivateTmp=yes
NoNewPrivileges=yes
UNIT
  done <<<"$map"
fi

# Remove relays that are no longer wanted: the feature is off, or a node or
# port left the map.
shopt -s nullglob
for path in "$UNIT_DIR/$PREFIX"*.socket; do
  name="$(basename "$path" .socket)"; name="${name#"$PREFIX"}"
  [[ " ${want[*]} " == *" $name "* ]] && continue
  sudo systemctl disable --now "$PREFIX$name.socket" "$PREFIX$name.service" >/dev/null 2>&1 || true
  sudo rm -f "$UNIT_DIR/$PREFIX$name.socket" "$UNIT_DIR/$PREFIX$name.service"
  changed "relay $name removed"
done
sudo systemctl daemon-reload

for name in "${want[@]}"; do
  ensure_unit_enabled "$PREFIX$name.socket"
  ensure_unit_active "$PREFIX$name.socket"
done

if [[ "$enabled" == no ]]; then
  ok "LAN port forwards off (LAN_PORT_FORWARDS=no)"
  exit 0
fi

# The Windows half. The ports are the whole contract between the two halves.
ports="$(awk '{print $2}' <<<"$map" | paste -sd, -)"
{
  echo
  echo "LAN port forwards, head-node half in place. From any device on ${LAB_LAN_CIDR:-your LAN}:"
  while read -r name port target; do
    printf '  %-6s %-14s -> %s\n' "$port" "$name" "$target"
  done <<<"$map"
  echo
  echo "Windows half, once and again whenever this list changes. In an elevated PowerShell on the Windows host:"
  echo
  # Read through wsl rather than a \\wsl$ path: that share does not exist in
  # an SSH session. A script block from text needs no execution-policy change.
  echo "  & ([scriptblock]::Create((wsl -d ${LAB_WSL_DISTRO:-Ubuntu} -e cat $REPO_ROOT/scripts/windows/install-lan-ports.ps1 | Out-String))) -Ports $ports -LanCidr ${LAB_LAN_CIDR:-<your LAN CIDR>}"
} >&2
