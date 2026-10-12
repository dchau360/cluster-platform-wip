#!/usr/bin/env bash
# shellcheck shell=bash
#
# Boot-phase timing, read from each node's serial console.
#
# The DHCP lease is the first externally observable milestone, but it is not
# where boot ends and it does not say where the time went. The console names
# every stage already, so this watches the console a node is writing and turns
# those markers into records in the same per-node timing stream the harness
# already writes (`lib/timing.sh`).
#
# It is a watcher rather than a post-hoc parse for one reason: firmware and
# iPXE carry no timestamps of their own. Only the wall clock at the moment a
# marker appeared, observed live, gives them a duration. Post-processing the
# finished log could not do it.
#
# Requires lib/timing.sh (phase_begin/phase_end/phase_skip) and
# lib/common.sh (warn) to have been sourced, and runs in the background so it
# can observe a boot while the caller continues.
#
# Boundaries, in order, per node:
#
#   firmware   power-on through the UEFI PXE boot manager; ends when iPXE runs
#   ipxe       iPXE init, DHCP and the iPXE script fetch; ends at the kernel
#              fetch
#   kernel     the kernel fetch
#   initramfs  the boot-menu wait and the initramfs fetch
#   overlay    the dracut stage: image, system and runtime overlay fetch+apply
#   login      pivot to the node root and systemd start, through the prompt

BOOT_PHASE_ORDER=(firmware ipxe kernel initramfs overlay login)

# The substring that ends each phase. `kernel` and `initramfs` additionally
# require "ok", because the download-failure path prints the same URL without
# it and a failed fetch must not read as a completed phase.
declare -A BOOT_PHASE_MARKER=(
  [firmware]='iPXE initialising devices'
  [ipxe]='Downloading kernel image'
  [kernel]='/kernel/'
  [initramfs]='/initramfs/'
  [overlay]='warewulf: invoking /sbin/init'
  [login]='login:'
)

_boot_phase_marker_seen() {
  local phase="$1" buf="$2"
  local marker="${BOOT_PHASE_MARKER[$phase]}"
  case "$phase" in
    kernel|initramfs)
      [[ "$buf" == *"$marker"*"ok"* ]] ;;
    *)
      [[ "$buf" == *"$marker"* ]] ;;
  esac
}

# boot_phases_skip <node> <reason>
#
# Record every boot phase as skipped. A node that was already running did not
# boot this run, so timing it would be a measurement of nothing.
boot_phases_skip() {
  local node="$1" reason="$2" phase
  for phase in "${BOOT_PHASE_ORDER[@]}"; do
    phase_skip "$phase" "$node" "$reason"
  done
}

# boot_phases_watch <node> <console-log> <byte-offset>
#
# Follow one node's console from <byte-offset> and record the boot phases.
# Intended to run in the background, started immediately after `virsh start`,
# with <byte-offset> the size of the console file before that boot appended to
# it. Returns 0 once the login prompt is seen, non-zero on timeout, after
# recording status=fail on the phase that never ended.
boot_phases_watch() {
  local node="$1" log="$2" offset="${3:-0}"
  local timeout="${BOOT_PHASE_TIMEOUT:-300}"
  local deadline=$(( $(date +%s) + timeout ))
  local idx=0 phase buf="" last="$offset" size chunk

  phase="${BOOT_PHASE_ORDER[$idx]}"
  phase_begin "$phase" "$node"

  while (( $(date +%s) < deadline )); do
    size="$(sudo stat -c %s "$log" 2>/dev/null || printf 0)"
    if (( size > last )); then
      # Only this boot's bytes. `tr -d '\r'` collapses the console's CRLF so a
      # marker cannot be split across a carriage return.
      chunk="$(sudo tail -c +$(( last + 1 )) "$log" 2>/dev/null | tr -d '\r' || true)"
      last="$size"
      buf+="$chunk"
      while _boot_phase_marker_seen "$phase" "$buf"; do
        phase_end "$phase" "$node" ok
        idx=$(( idx + 1 ))
        (( idx < ${#BOOT_PHASE_ORDER[@]} )) || return 0
        phase="${BOOT_PHASE_ORDER[$idx]}"
        phase_begin "$phase" "$node"
      done
    fi
    sleep 0.3
  done

  warn "boot phases for $node still in '$phase' after ${timeout}s"
  phase_end "$phase" "$node" fail
  return 1
}
