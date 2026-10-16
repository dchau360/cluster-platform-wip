#!/usr/bin/env bash
#
# `make up` — bring the lab platform to its desired state.
#
# Reconcile, do not rebuild. Every step reports `ok` when the system is
# already correct and `changed` only when it had to act, so a second run in
# a row reports changed=0. `make verify-idempotent` asserts exactly that.
#
# This does NOT start nodes. `make demo N=<n>` does.

export LAB_SCRIPT_NAME=up
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
lab_load_env
counters_init
timing_init

timed preflight "" -- bash "$HERE/preflight.sh"

# Unit files first: the segment must come back after a cold start without a
# manual step, and that is a property of the units, not of this script.
timed systemd-install "" -- bash "$HERE/systemd-install.sh"

# Reconcile the segment in this process so configuration drift is corrected
# and counted. The systemd unit runs the same script at boot.
timed net "" -- bash "$HERE/net-up.sh"

# Relays for LAN_PORT_FORWARDS, or their removal when it is off.
timed lan-ports "" -- bash "$HERE/lan-ports.sh"

# Mark the units active and enabled. Starting an already-active unit is a
# no-op, so this costs nothing on a repeat run.
phase_begin services
ensure_unit_enabled lab-net.service
ensure_unit_enabled lab-dnsmasq.service
ensure_unit_enabled lab.target
ensure_unit_active lab-net.service
ensure_unit_active lab-dnsmasq.service
phase_end services

counters_report
printf 'segment %s on %s, dnsmasq bound to %s only\n' "$PROV_CIDR" "$PROV_BRIDGE" "$PROV_GW"
