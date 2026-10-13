#!/usr/bin/env bash
#
# Cold-start gate.
#
# A Windows reboot or `wsl --shutdown` stops the whole distribution. If one
# lab service is merely running rather than enabled, the lab comes back
# half-alive and the failure surfaces later as a mystery. This asserts that
# every unit the lab depends on is enabled at boot.

export LAB_SCRIPT_NAME=cold-start-check
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

REQUIRED_ENABLED=(
  lab.target
  lab-net.service
  lab-dnsmasq.service
  libvirtd.socket
  docker.service
  nginx.service
  mariadb.service
  slurmdbd.service
  slurmctld.service
)

# Start order that matters on a cold start: "<unit> <must start after>".
REQUIRED_ORDER=(
  "slurmdbd.service mariadb.service"
  "slurmctld.service slurmdbd.service"
)

# These must NOT be enabled: they would race our own dnsmasq for the port.
REQUIRED_MASKED=(
  dnsmasq.service
  tftpd-hpa.service
)

fails=0
printf '%-24s %-12s %s\n' UNIT STATE VERDICT
for unit in "${REQUIRED_ENABLED[@]}"; do
  # `systemctl is-enabled` prints the state AND exits non-zero for states
  # like masked or disabled, so a `|| echo` fallback would append a second
  # word to a perfectly good answer.
  # `|| true` because pipefail is on and is-enabled exits non-zero for
  # masked and disabled, which are the answers this loop is looking for.
  state="$(systemctl is-enabled "$unit" 2>/dev/null | head -1 || true)"
  state="${state:-missing}"
  if [[ "$state" == "enabled" || "$state" == "enabled-runtime" ]]; then
    printf '%-24s %-12s PASS\n' "$unit" "$state"
  else
    printf '%-24s %-12s FAIL must be enabled at boot\n' "$unit" "$state"
    fails=$((fails + 1))
  fi
done

for unit in "${REQUIRED_MASKED[@]}"; do
  # `|| true` because pipefail is on and is-enabled exits non-zero for
  # masked and disabled, which are the answers this loop is looking for.
  state="$(systemctl is-enabled "$unit" 2>/dev/null | head -1 || true)"
  state="${state:-missing}"
  if [[ "$state" == "masked" || "$state" == "missing" || "$state" == "disabled" ]]; then
    printf '%-24s %-12s PASS\n' "$unit" "$state"
  else
    printf '%-24s %-12s FAIL would fight lab-dnsmasq for the port\n' "$unit" "$state"
    fails=$((fails + 1))
  fi
done

for pair in "${REQUIRED_ORDER[@]}"; do
  unit="${pair%% *}" first="${pair#* }"
  after=" $(systemctl show "$unit" --property=After --value 2>/dev/null || true) "
  if [[ "$after" == *" $first "* ]]; then
    printf '%-24s %-12s PASS starts after %s\n' "$unit" ordered "$first"
  else
    printf '%-24s %-12s FAIL must start after %s\n' "$unit" unordered "$first"
    fails=$((fails + 1))
  fi
done

echo
if (( fails > 0 )); then
  echo "RESULT: $fails unit(s) wrong. Cold start would not recover cleanly."
  exit 1
fi
echo "RESULT: every lab unit is enabled at boot"
