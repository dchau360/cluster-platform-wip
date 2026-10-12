#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the lab harness.
#
# Two things every harness script gets from here:
#
#   * Configuration. lab/local.env.example supplies defaults, lab/local.env
#     overrides them. Nothing in this repo reads a host value any other way.
#   * A change counter. Every action reports either `ok` (already correct) or
#     `changed` (it had to act). `make up` run twice must report zero changes
#     on the second run, and the counter is what proves it.

set -euo pipefail

# Needs bash 4 (mapfile, associative arrays). Say so plainly: a gate that dies
# with "mapfile: command not found" looks broken rather than unsupported.
# macOS ships bash 3.2; use `brew install bash`.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export REPO_ROOT

LAB_ENV_EXAMPLE="$REPO_ROOT/lab/local.env.example"
LAB_ENV_FILE="${LAB_ENV_FILE:-$REPO_ROOT/lab/local.env}"

_C_RED=''; _C_GRN=''; _C_YLW=''; _C_BLU=''; _C_RST=''
if [[ -t 1 ]]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YLW=$'\033[33m'
  _C_BLU=$'\033[36m'; _C_RST=$'\033[0m'
fi

# The same scripts run two ways: from `make` as the operator, and from a
# systemd unit as root. Rather than thread a privilege variable through
# every command, keep the call sites written with `sudo` and make it a
# transparent no-op when we are already root.
if [[ "$EUID" -eq 0 ]]; then
  sudo() { while [[ "${1:-}" == -* ]]; do shift; done; "$@"; }
fi

log()  { printf '%s[%s]%s %s\n' "$_C_BLU" "${LAB_SCRIPT_NAME:-lab}" "$_C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$_C_YLW" "$_C_RST" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

lab_load_env() {
  [[ -f "$LAB_ENV_EXAMPLE" ]] || die "missing $LAB_ENV_EXAMPLE"

  # A value the caller already set wins over both files, so a one-off
  # `CONVERGENCE_STALE_SECONDS=60 make convergence-status` does what it says
  # instead of being silently replaced by the default.
  local -A caller_env=()
  local key
  while IFS= read -r key; do
    [[ -n "${!key+x}" ]] && caller_env[$key]="${!key}"
  done < <(cat "$LAB_ENV_EXAMPLE" "$LAB_ENV_FILE" 2>/dev/null \
             | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d = | sort -u)

  set -a
  # Defaults. Host-specific keys are blank here on purpose.
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$LAB_ENV_EXAMPLE")
  if [[ -f "$LAB_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$LAB_ENV_FILE")
  fi
  set +a
  for key in "${!caller_env[@]}"; do
    export "$key=${caller_env[$key]}"
  done

  # `N` on the make command line always wins. Nothing in this repo may
  # assume a node count.
  if [[ -n "${N:-}" ]]; then
    if [[ ! "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
      die "N must be a positive integer, got '${N}'"
    fi
    NODE_COUNT="$N"
  fi
  export NODE_COUNT

  LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/cluster-lab}"
  export LAB_STATE_DIR
  export LAB_TFTP_DIR="$LAB_STATE_DIR/tftp"
  export LAB_IMAGE_DIR="$LAB_STATE_DIR/images"
  export LAB_RUN_DIR="$LAB_STATE_DIR/run"
  export LAB_TIMING_DIR="$LAB_STATE_DIR/timings"

  lab_bootstrap_state
}

# The change counter and the timing log are written before preflight gets a
# chance to run, so their directories cannot be created by preflight. This
# creates them, below the change-accounting layer on purpose: it reports
# nothing, and preflight still accounts for them afterwards.
lab_bootstrap_state() {
  local owner="${LAB_WSL_USER:-${USER:-$(id -un)}}" d
  for d in "$LAB_STATE_DIR" "$LAB_RUN_DIR" "$LAB_TIMING_DIR"; do
    [[ -d "$d" ]] || sudo mkdir -p "$d"
  done
  # The lab user owns what the lab user writes. Everything else under
  # LAB_STATE_DIR stays root-owned, because root services write it.
  for d in "$LAB_RUN_DIR" "$LAB_TIMING_DIR"; do
    [[ -w "$d" ]] || sudo chown "$owner" "$d"
  done
}

lab_require_env() {
  local missing=()
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || missing+=("$key")
  done
  if (( ${#missing[@]} > 0 )); then
    die "not set in $LAB_ENV_FILE: ${missing[*]}
     Copy lab/local.env.example to lab/local.env and fill these in."
  fi
}

# Node name for index 1..NODE_COUNT. Zero-padded to two digits.
node_name() { printf '%s%02d' "${NODE_NAME_PREFIX:-cn}" "$1"; }

# Deterministic synthetic MAC for index 1..NODE_COUNT, built from the
# locally-administered OUI so it can never collide with real hardware.
node_mac() {
  printf '%s:%02x:%02x:%02x' "${PROV_MAC_OUI:-52:54:00}" \
    $(( ($1 >> 16) & 0xff )) $(( ($1 >> 8) & 0xff )) $(( $1 & 0xff ))
}

# Address handed out statically to node index 1..NODE_COUNT. The offset is
# a variable so the formula has one definition; the Warewulf role reads the
# same variable to define a node's address in Warewulf's database.
node_ip() { printf '10.42.0.%d' $(( ${PROV_NODE_IP_OFFSET:-10} + $1 )); }

lab_node_indexes() { seq 1 "${NODE_COUNT}"; }

# ---------------------------------------------------------------------------
# Change accounting
# ---------------------------------------------------------------------------

_counter_file() { printf '%s' "${LAB_COUNTER_FILE:-$LAB_RUN_DIR/changes}"; }

counters_init() {
  mkdir -p "$(dirname "$(_counter_file)")"
  printf '0 0\n' > "$(_counter_file)"
}

_bump() {
  local f; f="$(_counter_file)"
  [[ -f "$f" ]] || counters_init
  local c o; read -r c o < "$f"
  case "$1" in
    changed) c=$((c + 1)) ;;
    ok)      o=$((o + 1)) ;;
  esac
  printf '%s %s\n' "$c" "$o" > "$f"
}

# An action had to act.
changed() { _bump changed; printf '%schanged%s %s\n' "$_C_YLW" "$_C_RST" "$*"; }
# An action found the system already correct.
ok()      { _bump ok;      printf '%sok%s      %s\n' "$_C_GRN" "$_C_RST" "$*"; }

counters_changed() { local c o; read -r c o < "$(_counter_file)"; printf '%s' "$c"; }
counters_ok()      { local c o; read -r c o < "$(_counter_file)"; printf '%s' "$o"; }

counters_report() {
  local c o; read -r c o < "$(_counter_file)"
  printf '\nRESULT: changed=%s ok=%s\n' "$c" "$o"
}

# ---------------------------------------------------------------------------
# Idempotent primitives. Each one reports ok or changed.
# ---------------------------------------------------------------------------

# ensure_dir <path> [mode] [owner]
ensure_dir() {
  local path="$1" mode="${2:-0755}" owner="${3:-}"
  if [[ -d "$path" ]]; then
    ok "dir $path"
  else
    sudo mkdir -p "$path"
    sudo chmod "$mode" "$path"
    [[ -z "$owner" ]] || sudo chown "$owner" "$path"
    changed "dir $path created"
  fi
}

# ensure_file_content <path> <mode> < content-on-stdin
ensure_file_content() {
  local path="$1" mode="${2:-0644}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && sudo cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    ok "file $path"
  else
    sudo mkdir -p "$(dirname "$path")"
    sudo install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    changed "file $path written"
  fi
}

# ensure_unit_enabled <unit>
ensure_unit_enabled() {
  local unit="$1"
  if [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]]; then
    ok "unit $unit enabled"
  else
    sudo systemctl enable "$unit" >/dev/null
    changed "unit $unit enabled"
  fi
}

# ensure_unit_active <unit>
ensure_unit_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    ok "unit $unit active"
  else
    sudo systemctl start "$unit"
    changed "unit $unit started"
  fi
}

# ---------------------------------------------------------------------------

# Drop the dnsmasq lease for each MAC given, so the next lease observed for it
# can only be one issued after this call.
#
# The dhcp-lease phase is measured by watching for the MAC in the lease file.
# A lease left by a previous run matches on the first look, so the phase
# reports 0.03s for something that takes five seconds — and reports it as `ok`.
# `make nodes-down` without WIPE keeps the lease file, and that is the normal
# cheap way to cycle nodes, so this is the common path rather than an edge
# case. The 1-to-N curve is a deliverable, so a phase that can silently
# measure nothing is worse than one that fails.
#
# dnsmasq also keeps leases in memory and owns the file, so editing the file is
# only half of it: the daemon has to be restarted to re-read it. Same reason
# the WIPE path in nodes-down.sh restarts it.
lease_forget() {
  local leases="$LAB_STATE_DIR/dnsmasq/leases" m pattern='' n
  [[ -f "$leases" ]] || return 0
  (( $# > 0 )) || return 0

  for m in "$@"; do
    [[ -n "$m" ]] || continue
    pattern+="${pattern:+|}$(printf '%s' "$m" | sed 's/[][\.*^$|()+?{}]/\\&/g')"
  done
  [[ -n "$pattern" ]] || return 0

  # Find out whether anything matches BEFORE touching the file.
  #
  # `sed -i` does not edit in place: it writes a new file and renames it over
  # the old one, so it replaces the inode even when it changes no bytes. And
  # dnsmasq holds the old inode open. Editing unconditionally would leave the
  # daemon appending to a deleted file, making every later lease invisible —
  # the wait then times out on a node that booted perfectly. That is the same
  # failure the WIPE path in nodes-down.sh restarts the daemon to avoid, and
  # the first version of this function walked straight back into it: it ran
  # sed for every MAC, found nothing removed, and so skipped the restart.
  #
  # So: touch nothing unless there is something to remove, and restart
  # whenever the file was touched.
  n="$(sudo grep -ciE "$pattern" "$leases" 2>/dev/null || true)"
  n="${n:-0}"
  if (( n == 0 )); then
    ok "no stale dhcp lease to clear"
    return 0
  fi

  sudo sed -i -E "/$pattern/Id" "$leases"
  changed "cleared $n stale dhcp lease(s) so the wait measures this boot"
  if systemctl is-active --quiet lab-dnsmasq.service; then
    sudo systemctl restart lab-dnsmasq.service
    changed "lab-dnsmasq restarted so it reopens the lease file"
  fi
}

lab_init() {
  LAB_SCRIPT_NAME="${LAB_SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-lab}" .sh)}"
  lab_load_env
}
