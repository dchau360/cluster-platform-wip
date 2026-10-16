#!/usr/bin/env bash
#
# make lan-access — the two steps outside WSL that LAB_LAN_ACCESS=yes needs.
#
# Prints, does not run: both steps happen outside the lab. One is an
# administrator PowerShell on the Windows host, the other is your router.
# `make up` already did the WSL half (forwarding plus the nftables rules that
# let LAB_LAN_CIDR reach the segment on SSH and ping, and nothing else).

export LAB_SCRIPT_NAME=lan-access
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

[[ "${LAB_LAN_ACCESS:-no}" =~ ^(yes|true|1)$ ]] \
  || die "LAB_LAN_ACCESS is not yes in lab/local.env; set it and run make up first"
[[ -n "${LAB_LAN_CIDR:-}" ]] || die "LAB_LAN_CIDR is not set in lab/local.env"
win_host="${LAB_HOST_SSH#*@}"
[[ -n "$win_host" ]] || win_host="<the Windows host's LAN address>"
win_dir="$(wslpath -w "$HERE/windows" 2>/dev/null || echo '<repo>\scripts\windows')"

cat <<STEPS
1. On Windows, in an administrator PowerShell (once; it keeps itself in place):

   cd "$win_dir"
   powershell -ExecutionPolicy Bypass -File .\\install-lan-route.ps1 -Subnet $PROV_CIDR -LanCidr $LAB_LAN_CIDR -LanInterface Wi-Fi

   Use the adapter name your Windows host is on the LAN with (Get-NetAdapter),
   for example Ethernet instead of Wi-Fi.

2. On your router, add a static route:

   destination  $PROV_CIDR
   gateway      $win_host

Then, from any machine on $LAB_LAN_CIDR:  ssh root@<node address>  (node 1 is ${PROV_CIDR%.*}.20)
STEPS
