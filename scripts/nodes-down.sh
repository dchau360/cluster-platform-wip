#!/usr/bin/env bash
#
# Stop and undefine every lab node. Disk images and nvram are removed only
# when WIPE=1, so a `make down` / `make up` cycle does not force a rebuild.

export LAB_SCRIPT_NAME=nodes-down
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

VIRSH=(sudo virsh --connect "$LIBVIRT_URI")
WIPE="${WIPE:-0}"

# Act on every domain carrying the lab prefix, not only on 1..NODE_COUNT.
# Otherwise lowering N would orphan the nodes above the new count.
mapfile -t DOMAINS < <("${VIRSH[@]}" list --all --name 2>/dev/null \
  | grep -E "^${NODE_NAME_PREFIX}[0-9]+$" || true)

if (( ${#DOMAINS[@]} == 0 )); then
  ok "no lab domains defined"
else
  for name in "${DOMAINS[@]}"; do
    if [[ "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || true)" == running ]]; then
      "${VIRSH[@]}" shutdown "$name" >/dev/null 2>&1 || true
      deadline=$(( $(date +%s) + VM_SHUTDOWN_TIMEOUT ))
      while (( $(date +%s) < deadline )); do
        [[ "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || true)" == running ]] || break
        sleep 1
      done
      if [[ "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || true)" == running ]]; then
        "${VIRSH[@]}" destroy "$name" >/dev/null
      fi
      changed "domain $name stopped"
    else
      ok "domain $name not running"
    fi

    "${VIRSH[@]}" undefine --nvram "$name" >/dev/null
    changed "domain $name undefined"

    if [[ "$WIPE" == "1" ]]; then
      sudo rm -f "$LAB_VM_DIR/${name}.qcow2" "$LAB_VM_DIR/nvram/${name}.fd"
      changed "disk and nvram for $name removed"
    fi
  done
fi

if [[ "$WIPE" == "1" ]]; then
  sudo rm -f "$LAB_STATE_DIR/dnsmasq/leases"
  changed "dhcp leases cleared"
  # dnsmasq holds the lease file open. Removing it leaves the daemon
  # writing to a deleted inode, so every later lease is invisible and the
  # next `make demo` waits out its timeout for nothing. Restart it.
  if systemctl is-active --quiet lab-dnsmasq.service; then
    sudo systemctl restart lab-dnsmasq.service
    changed "lab-dnsmasq restarted so it reopens the lease file"
  fi
fi
