#!/usr/bin/env bash
#
# `make down` — stop the lab. Nodes first, then the segment.
#
# Unit files stay installed and enabled, so a Windows reboot still brings
# the lab back. `make down-hard` disables them too.

export LAB_SCRIPT_NAME=down
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env
counters_init

bash "$HERE/nodes-down.sh"

for unit in lab-dnsmasq.service lab-net.service; do
  if systemctl is-active --quiet "$unit"; then
    sudo systemctl stop "$unit"
    changed "unit $unit stopped"
  else
    ok "unit $unit not active"
  fi
done

# lab-net.service has ExecStop=net-down.sh, so stopping it removes the
# bridge. Run net-down directly too, in case the unit was never installed.
bash "$HERE/net-down.sh"

if [[ "${HARD:-0}" == "1" ]]; then
  for unit in lab.target lab-dnsmasq.service lab-net.service; do
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]]; then
      sudo systemctl disable "$unit" >/dev/null
      changed "unit $unit disabled"
    else
      ok "unit $unit not enabled"
    fi
  done
fi

counters_report
