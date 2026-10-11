#!/usr/bin/env bash
#
# Install the lab systemd units.
#
# A Windows reboot or `wsl --shutdown` stops everything in the distribution.
# Cold-start recovery has to be a tested path, so every lab service is a
# systemd unit enabled at boot rather than something an operator remembers
# to start.
#
# Units are rendered from systemd/*.in because they must carry the repo path
# and the state directory, and those differ per host. The templates are
# tracked; the rendered units are not.

export LAB_SCRIPT_NAME=systemd-install
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
lab_load_env

UNIT_DIR=/etc/systemd/system
TEMPLATE_DIR="$REPO_ROOT/systemd"

reloaded=0
for tpl in "$TEMPLATE_DIR"/*.in; do
  [[ -f "$tpl" ]] || continue
  unit="$(basename "$tpl" .in)"
  before="$(counters_changed)"
  sed -e "s#@REPO_ROOT@#$REPO_ROOT#g" \
      -e "s#@LAB_STATE_DIR@#$LAB_STATE_DIR#g" \
      -e "s#@LAB_RUN_DIR@#$LAB_RUN_DIR#g" \
      -e "s#@LAB_USER@#${LAB_WSL_USER:-$USER}#g" \
      "$tpl" | ensure_file_content "$UNIT_DIR/$unit" 0644
  [[ "$(counters_changed)" == "$before" ]] || reloaded=1
done

if (( reloaded == 1 )); then
  sudo systemctl daemon-reload
  changed "systemd daemon reloaded"
else
  ok "systemd units up to date"
fi
