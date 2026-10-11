#!/usr/bin/env bash
#
# Host-value hygiene gate.
#
# These repos are public. Every commit is world-readable forever. This script
# fails the build if a value that identifies the lab host can be found in a
# tracked file.
#
# It runs four independent checks:
#
#   1. lab/local.env must not be tracked.
#   2. Exact match: every value in lab/local.env that differs from the value
#      shipped in lab/local.env.example is searched for in all tracked files.
#      Only the VARIABLE NAME is ever printed. The value is never printed.
#   3. IPv4 allowlist: a tracked file may only contain addresses from the
#      provisioning segment or from the RFC 5737 documentation ranges.
#      Everything else is a finding, including any home-LAN literal.
#   4. MAC allowlist: a tracked file may only contain MAC addresses from the
#      locally-administered range, so no real NIC can ever be recorded.
#
# Check 2 needs lab/local.env. On the lab host that file is simply present.
# In CI it is written from the LAB_LOCAL_ENV repository secret when available.
# Checks 1, 3 and 4 always run and need no secret, so a fork pull request
# still gets a meaningful gate.
#
# Usage:  scripts/check-no-host-values.sh
# Exit:   0 clean, 1 findings.

set -euo pipefail

# Needs bash 4 (mapfile, associative arrays). Say so plainly: a gate that dies
# with "mapfile: command not found" looks broken rather than unsupported.
# macOS ships bash 3.2; use `brew install bash`.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

ENV_FILE="${LAB_ENV_FILE:-lab/local.env}"
ENV_EXAMPLE="lab/local.env.example"

RED=''; GRN=''; YLW=''; RST=''
if [[ -t 1 ]]; then RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'; fi

findings=0
finding() { findings=$((findings + 1)); printf '%sFAIL%s %s\n' "$RED" "$RST" "$*"; }
pass()    { printf '%sok%s   %s\n' "$GRN" "$RST" "$*"; }
skip()    { printf '%sskip%s %s\n' "$YLW" "$RST" "$*"; }
section() { printf '\n== %s\n' "$*"; }

# Split one `file:line:text` record from git grep. Matched text may contain
# colons, so only the first two fields are consumed.
G_FILE=''; G_LINE=''; G_TEXT=''
parse_grep_record() {
  [[ "$1" =~ ^([^:]+):([0-9]+):(.*)$ ]] || return 1
  G_FILE="${BASH_REMATCH[1]}"
  G_LINE="${BASH_REMATCH[2]}"
  G_TEXT="${BASH_REMATCH[3]}"
}

# Tracked text files, excluding the example file, which is allowed to carry
# placeholder and lab-internal values by design.
mapfile -t SCAN_FILES < <(git ls-files | grep -vFx "$ENV_EXAMPLE" || true)
if [[ ${#SCAN_FILES[@]} -eq 0 ]]; then
  echo "no tracked files to scan"
  exit 0
fi

# ---------------------------------------------------------------------------
# Check 1 — lab/local.env is not tracked
# ---------------------------------------------------------------------------
section "check 1: lab/local.env is untracked"
if git ls-files --error-unmatch "$ENV_FILE" >/dev/null 2>&1; then
  finding "$ENV_FILE is tracked by git. It must never be committed."
else
  pass "$ENV_FILE is not tracked"
fi

# ---------------------------------------------------------------------------
# Check 2 — exact match on every host-specific value
# ---------------------------------------------------------------------------
section "check 2: no value from $ENV_FILE appears in a tracked file"
if [[ ! -f "$ENV_FILE" ]]; then
  skip "$ENV_FILE not present; exact-match check not run (checks 1, 3, 4 still apply)"
else
  unquote() { local v="$1"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"; }

  declare -A EXAMPLE_VAL=()
  if [[ -f "$ENV_EXAMPLE" ]]; then
    while IFS='=' read -r k v; do
      [[ -n "$k" ]] || continue
      EXAMPLE_VAL["$k"]="$(unquote "$v")"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_EXAMPLE" || true)
  fi

  checked=0
  exact_hits=0
  while IFS='=' read -r key val; do
    [[ -n "$key" ]] || continue
    val="$(unquote "$val")"

    # Nothing to leak.
    [[ -n "$val" ]] || continue
    # Identical to the shipped example: by definition not host-specific.
    [[ "${EXAMPLE_VAL[$key]-$'\x01'}" != "$val" ]] || continue
    # Too short or purely numeric: cannot identify a host and would only
    # produce noise. Node counts, memory sizes and timeouts live here.
    (( ${#val} >= 4 )) || continue
    [[ ! "$val" =~ ^[0-9]+$ ]] || continue

    checked=$((checked + 1))
    if hits="$(git grep -I -F -l -e "$val" -- "${SCAN_FILES[@]}" 2>/dev/null | paste -sd' ' -)" \
       && [[ -n "$hits" ]]; then
      # Print the variable name and the files. Never the value itself.
      exact_hits=$((exact_hits + 1))
      finding "value of $key from $ENV_FILE appears in: $hits"
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || true)

  (( exact_hits > 0 )) \
    || pass "$checked host-specific value(s) checked, none found in tracked files"
fi

# ---------------------------------------------------------------------------
# Check 3 — IPv4 allowlist
# ---------------------------------------------------------------------------
section "check 3: only allowlisted IPv4 literals in tracked files"

# Allowed: the provisioning segment, loopback and wildcard addresses,
# common netmasks, and the three RFC 5737 documentation ranges.
ip_allowed() {
  case "$1" in
    10.42.0.*)                                 return 0 ;;  # provisioning segment
    127.0.0.1)                                 return 0 ;;
    0.0.0.0)                                   return 0 ;;
    255.255.255.0|255.255.255.255|255.255.0.0) return 0 ;;
    192.0.2.*)                                 return 0 ;;  # RFC 5737 TEST-NET-1
    198.51.100.*)                              return 0 ;;  # RFC 5737 TEST-NET-2
    203.0.113.*)                               return 0 ;;  # RFC 5737 TEST-NET-3
    *)                                         return 1 ;;
  esac
}

ip_hits=0
while IFS= read -r record; do
  parse_grep_record "$record" || continue
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    # Reject octets above 255 so version strings do not raise findings.
    bad=0
    IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do (( 10#$o <= 255 )) || bad=1; done
    (( bad == 0 )) || continue
    if ! ip_allowed "$ip"; then
      ip_hits=$((ip_hits + 1))
      finding "$G_FILE:$G_LINE contains non-allowlisted IPv4 literal $ip"
    fi
  done < <(printf '%s\n' "$G_TEXT" \
           | grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' \
           | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
done < <(git grep -I -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}' -- "${SCAN_FILES[@]}" || true)
(( ip_hits > 0 )) || pass "no non-allowlisted IPv4 literal found"

# ---------------------------------------------------------------------------
# Check 4 — MAC addresses must be locally administered
# ---------------------------------------------------------------------------
section "check 4: only locally-administered MAC addresses in tracked files"

mac_hits=0
while IFS= read -r record; do
  parse_grep_record "$record" || continue
  while read -r mac; do
    [[ -n "$mac" ]] || continue
    # The second hex digit carries the locally-administered bit.
    case "${mac:1:1}" in
      2|6|a|e|A|E) ;;
      *) mac_hits=$((mac_hits + 1))
         finding "$G_FILE:$G_LINE contains MAC $mac which is not locally administered" ;;
    esac
  done < <(printf '%s\n' "$G_TEXT" \
           | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || true)
done < <(git grep -I -n -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' -- "${SCAN_FILES[@]}" || true)
(( mac_hits > 0 )) || pass "no globally-unique MAC address found"

# ---------------------------------------------------------------------------
section "result"
if (( findings > 0 )); then
  printf '%s%d finding(s). Host-specific data must live in %s, which is untracked.%s\n' \
    "$RED" "$findings" "$ENV_FILE" "$RST"
  exit 1
fi
printf '%sclean%s\n' "$GRN" "$RST"
