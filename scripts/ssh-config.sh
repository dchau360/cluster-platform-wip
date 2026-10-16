#!/usr/bin/env bash
#
# make ssh-config — the ~/.ssh/config block for your workstation.
#
# Prints, does not write: the block belongs on the machine you type on, not on
# the lab host. Append it there once:
#
#   ssh <lab host> wsl -e make -C <repo> -s ssh-config >> ~/.ssh/config
#
# Three hops, all ordinary ssh. The workstation reaches Windows (LAB_HOST_SSH);
# `wsl -e nc` turns that into a TCP stream to the head node's sshd inside WSL,
# so nothing on Windows is reconfigured and no WSL address that changes on a
# restart is ever written down; nodes are reached through the head node, which
# is the only thing on the provisioning segment's side. The tunnel host
# forwards the head node's web UIs, which listen on its loopback only.

export LAB_SCRIPT_NAME=ssh-config
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

[[ -n "${LAB_HOST_SSH:-}" ]] || die "LAB_HOST_SSH is not set in lab/local.env"
win_user="${LAB_HOST_SSH%@*}"
win_host="${LAB_HOST_SSH#*@}"
[[ "$win_user" != "$LAB_HOST_SSH" ]] || win_user="$USER"

cat <<CONFIG
# --- cluster lab, from \`make ssh-config\` -------------------------------
# The Windows box the lab runs on.
Host cluster-win
  HostName $win_host
  User $win_user

# The head node: NetBox, Warewulf, slurmctld, Prometheus. \`ssh cluster\`.
Host cluster
  HostName cluster-head
  User $(id -un)
  ProxyCommand ssh cluster-win wsl -d ${LAB_WSL_DISTRO:-Ubuntu} -e nc 127.0.0.1 22
  ServerAliveInterval 30

# The web UIs. \`ssh -N cluster-tunnel\`, then open the URLs below.
#   NetBox        http://localhost:8000
#   Prometheus    http://localhost:9090
#   Alertmanager  http://localhost:9093
Host cluster-tunnel
  HostName cluster-head
  User $(id -un)
  ProxyCommand ssh cluster-win wsl -d ${LAB_WSL_DISTRO:-Ubuntu} -e nc 127.0.0.1 22
  LocalForward 8000 127.0.0.1:8000
  LocalForward 9090 127.0.0.1:9090
  LocalForward 9093 127.0.0.1:9093
  ExitOnForwardFailure yes

# Any port on any node by address (macOS/Linux): sshuttle -r cluster $PROV_CIDR

# Every node, as root, through the head node. \`ssh ${NODE_NAME_PREFIX:-cn}01\`.
Host ${NODE_NAME_PREFIX:-cn}??
  User root
  ProxyJump cluster
  StrictHostKeyChecking accept-new
# --- end cluster lab ------------------------------------------------------
CONFIG
