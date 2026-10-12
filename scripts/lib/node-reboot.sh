#!/usr/bin/env bash
# shellcheck shell=bash
#
# Restart and observe one lab node, for the acceptance drills.
#
# `nodes-up.sh` owns the normal path: define from the node count, start, watch
# the boot phases. The drills do something different — they change one node's
# configuration first (a MAC swap, an image rollback) and then restart only
# that node, so they cannot reuse the loop in nodes-up.sh without undoing the
# change. The pieces are small enough to share.
#
# Requires lib/common.sh and lib/boot-phases.sh to have been sourced.

: "${LIBVIRT_URI:=qemu:///system}"
VIRSH=(sudo virsh --connect "$LIBVIRT_URI")

node_console_path() { printf '%s/console/%s.log' "$LAB_VM_DIR" "$1"; }

node_domain_mac() {
  "${VIRSH[@]}" dumpxml --inactive "$1" 2>/dev/null \
    | grep -oE "<mac address='[^']+'" | head -1 | cut -d"'" -f2
}

# node_boot <name>
#
# Power a stopped domain on and watch its serial console from byte zero in the
# background. Sets NODE_BOOT_WATCH_PID to the watcher so the caller can wait
# for the boot. Not printed and not captured with `$(...)`: the watcher keeps
# the stdout pipe open, so a command substitution would block until the whole
# boot finished and would swallow the phase markers with it. The caller must
# have stopped the domain; starting a running one would be a no-op and the
# watcher would follow a console nobody is writing.
NODE_BOOT_WATCH_PID=""
node_boot() {
  local name="$1" log
  log="$(node_console_path "$name")"
  ensure_dir "$LAB_VM_DIR/console" 0711 >&2
  sudo truncate -s 0 "$log" 2>/dev/null || true
  "${VIRSH[@]}" start "$name" >/dev/null
  boot_phases_watch "$name" "$log" 0 &
  # Read by the caller after the boot. shellcheck sees one file at a time.
  # shellcheck disable=SC2034
  NODE_BOOT_WATCH_PID=$!
}

# node_stop <name> — hard stop; the state that matters is on the server.
node_stop() {
  local name="$1"
  if [[ "$("${VIRSH[@]}" domstate "$name" 2>/dev/null || true)" == running ]]; then
    "${VIRSH[@]}" destroy "$name" >/dev/null
  fi
}

# node_wait_for_console <name> <ere-pattern> [timeout-seconds]
#
# Wait until the node's console matches the pattern. Returns non-zero on
# timeout so a caller can print the console tail and fail honestly.
node_wait_for_console() {
  local name="$1" pattern="$2" timeout="${3:-300}" log deadline
  log="$(node_console_path "$name")"
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if sudo grep -aqE "$pattern" "$log" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# node_console_value <name> <ere-pattern> — last match, CR stripped.
#
# The serial console writes CRLF, and `grep -o` will carry the `\r` into the
# match, which then fails every suffix comparison. Strip it here so callers
# compare plain text.
node_console_value() {
  local name="$1" pattern="$2" log
  log="$(node_console_path "$name")"
  sudo grep -aoE "$pattern" "$log" 2>/dev/null | tr -d '\r' | tail -1 || true
}
