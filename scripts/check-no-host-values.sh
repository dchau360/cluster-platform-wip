#!/usr/bin/env bash
#
# Host-value hygiene gate.
#
# These repos are public. Every commit is world-readable forever. This script
# fails the build if a value that identifies the lab host can be found in a
# tracked file.
#
# It runs six independent checks:
#
#   1. lab/local.env must not be tracked.
#   2. lab/host-specific.vars and the example must agree, and the example must
#      not ship a value for any variable the list names.
#   3. Every variable set in lab/local.env must be declared in the example.
#   4. Exact match: every value in lab/local.env that differs from the value
#      shipped in lab/local.env.example is searched for in all tracked files.
#      Only the VARIABLE NAME is ever printed. The value is never printed.
#   5. IPv4 allowlist: a tracked file may only contain addresses from the
#      provisioning segment or from the RFC 5737 documentation ranges.
#      Everything else is a finding, including any home-LAN literal.
#   6. MAC allowlist: a tracked file may only contain MAC addresses from the
#      locally-administered range, so no real NIC can ever be recorded.
#
# Which variables are host-specific is declared in lab/host-specific.vars, a
# tracked list of NAMES. The example carries a matching `# host-specific` tag
# next to each one, and the gate reports any disagreement between the two. The
# list is the authority on purpose: see the note above the HOST_SPECIFIC block.
#
# Check 2 exists because check 4 alone has a hole, and the hole is shaped like
# the mistake people actually make. Check 4 has to exempt any value equal to
# the one shipped in the example, or every shared default (PROV_CIDR,
# NODE_COUNT) raises a finding. But that exemption is keyed on the example, so
# writing the host's real value INTO the example is what silences it: the leak
# becomes the reason the gate stays quiet. And the example is the file that
# lives in the repository, so it is the file an operator edits by mistake.
# Check 2 closes the hole by requiring a host-specific variable to be declared
# and left empty there, and check 4 then never exempts a tagged variable for
# any reason.
#
# Checks 3 and 4 need lab/local.env. On the lab host that file is simply
# present. In CI it is written from the LAB_LOCAL_ENV repository secret when
# available. Checks 1, 2, 5 and 6 always run and need no secret, so a fork
# pull request still gets a meaningful gate — including check 2, which is the
# one that catches a real value committed to the example.
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
note()    { printf '%snote%s %s\n' "$YLW" "$RST" "$*"; }
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

# Strip an inline comment from an env value, following shell's own rule: a '#'
# only starts a comment when whitespace precedes it, so `VAR=#notacomment`
# keeps its value while `VAR=   # host-specific` is empty.
strip_inline_comment() {
  local v="$1"
  [[ "$v" =~ ^(.*[[:space:]])#.*$ ]] && v="${BASH_REMATCH[1]}"
  v="${v%"${v##*[![:space:]]}"}"          # rstrip
  v="${v#"${v%%[![:space:]]*}"}"          # lstrip
  printf '%s' "$v"
}

unquote() {
  local v; v="$(strip_inline_comment "$1")"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# --- which variables are host-specific -------------------------------------
#
# The authority is lab/host-specific.vars, a tracked list of NAMES. The
# example also carries a `# host-specific` tag next to each one so a reader
# sees the rule where the variable is, but the tag is not the authority, and
# that distinction is the whole point of the second file.
#
# The mistake this gate exists to catch is someone typing a real value over
# the commented declaration:
#
#   #LAB_WSL_USER=          # host-specific      becomes
#   LAB_WSL_USER=ubuntu
#
# One edit, and the tag is gone with it. A gate that read only the tags would
# see one fewer tagged variable and report `ok` — it would stop objecting at
# exactly the moment it was needed. Reading the manifest instead, the same edit
# fails twice: the name is still listed, so the missing tag is a finding and
# the assigned value is a finding.
#
# A line in the example may be commented out and still declare the variable.
# That is deliberate: the name stays documented in the repository while no
# value ships with it.
declare -A HOST_SPECIFIC=()
declare -A TAGGED=()
declare -A DECLARED=()
declare -A RETIRED=()

HS_MANIFEST="lab/host-specific.vars"
if [[ -f "$HS_MANIFEST" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    HOST_SPECIFIC["$name"]=1
  done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$HS_MANIFEST" | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || true)
fi

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
  # Capture the name before the next =~ overwrites BASH_REMATCH.
  name="${BASH_REMATCH[1]}"
  DECLARED["$name"]=1
  if [[ "$line" =~ [[:space:]]#[[:space:]]*host-specific([[:space:]]|$) ]]; then
    TAGGED["$name"]=1
  fi
  # A retired name is one the code no longer reads. It stays declared so a
  # local.env copied from an older example still passes check 3.
  if [[ "$line" =~ [[:space:]]#[[:space:]]*retired([[:space:]]|$) ]]; then
    RETIRED["$name"]=1
  fi
done < <(grep -E '^[[:space:]]*#?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$ENV_EXAMPLE" || true)

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
# Check 2 — the example ships no value for a host-specific variable
#
# Needs no secret, so this one runs on a fork pull request too. It is the
# check that catches a real host value committed to the example, which is the
# edit that would otherwise switch check 4 off for that variable.
# ---------------------------------------------------------------------------
section "check 2: the example declares host-specific variables and ships no value for them"
if [[ ! -f "$HS_MANIFEST" ]]; then
  finding "$HS_MANIFEST is missing. It is the list check 4 trusts; without it nothing is protected."
elif ! git ls-files --error-unmatch "$HS_MANIFEST" >/dev/null 2>&1; then
  # Present but untracked is the dangerous state: it passes on the machine
  # that has the file and silently protects nothing for anybody else. A
  # `*.vars` rule in .gitignore put the file in exactly this state once.
  finding "$HS_MANIFEST exists but is not tracked by git, so nobody else gets it. Check .gitignore: $(git check-ignore -v "$HS_MANIFEST" 2>/dev/null || echo 'not ignored, just never added')"
elif (( ${#HOST_SPECIFIC[@]} == 0 )); then
  finding "$HS_MANIFEST lists no variable. An empty list is an unguarded repository, not a clean one."
else
  example_hits=0
  for key in "${!HOST_SPECIFIC[@]}"; do
    # Must be documented in the example at all.
    if [[ -z "${DECLARED[$key]-}" ]]; then
      example_hits=$((example_hits + 1))
      finding "$key is listed in $HS_MANIFEST but is not declared in $ENV_EXAMPLE. Every host-specific variable must be named and documented there."
      continue
    fi
    # Must carry the tag, so a reader sees the rule next to the variable.
    if [[ -z "${TAGGED[$key]-}" ]]; then
      example_hits=$((example_hits + 1))
      finding "$key is listed in $HS_MANIFEST but its line in $ENV_EXAMPLE has lost the '# host-specific' tag. Overwriting the commented declaration with a value is what removes it."
    fi
    # Must not be assigned a value. Only an uncommented line ships one.
    line="$(grep -E "^[[:space:]]*$key=" "$ENV_EXAMPLE" | head -1 || true)"
    [[ -n "$line" ]] || continue
    val="$(unquote "${line#*=}")"
    [[ -n "$val" ]] || continue
    example_hits=$((example_hits + 1))
    finding "$ENV_EXAMPLE assigns a value to $key, which $HS_MANIFEST lists as host-specific. Leave it empty or comment it out; the real value belongs in $ENV_FILE."
  done
  # A tag with no manifest entry is the other direction of the same drift.
  for key in "${!TAGGED[@]}"; do
    [[ -n "${HOST_SPECIFIC[$key]-}" ]] && continue
    example_hits=$((example_hits + 1))
    finding "$key is tagged '# host-specific' in $ENV_EXAMPLE but is not listed in $HS_MANIFEST, so check 4 does not treat it as host-specific."
  done
  (( example_hits > 0 )) \
    || pass "${#HOST_SPECIFIC[@]} host-specific variable(s) listed, each tagged in the example and none carrying a value"
fi

# ---------------------------------------------------------------------------
# Check 3 — every variable in lab/local.env is declared in the example
#
# The deliverable is that every host-specific variable is named and documented
# in the example. A variable that exists only in the real file is one nobody
# reviewing the repository can see, and check 2 cannot judge what it never
# learns about.
# ---------------------------------------------------------------------------
section "check 3: every variable in $ENV_FILE is declared in the example"
if [[ ! -f "$ENV_FILE" ]]; then
  skip "$ENV_FILE not present; declaration check not run (checks 1, 2, 5, 6 still apply)"
else
  undeclared=0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    [[ -n "${DECLARED[$key]-}" ]] && continue
    undeclared=$((undeclared + 1))
    finding "$key is set in $ENV_FILE but is not declared in $ENV_EXAMPLE"
  done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$ENV_FILE" | sort -u || true)
  (( undeclared > 0 )) || pass "every variable in $ENV_FILE is declared in the example"
  while IFS= read -r key; do
    [[ -n "$key" && -n "${RETIRED[$key]-}" ]] || continue
    note "$key is retired and ignored; it can be deleted from $ENV_FILE"
  done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$ENV_FILE" | sort -u || true)
fi

# ---------------------------------------------------------------------------
# Check 4 — exact match on every host-specific value
# ---------------------------------------------------------------------------
section "check 4: no value from $ENV_FILE appears in a tracked file"
if [[ ! -f "$ENV_FILE" ]]; then
  skip "$ENV_FILE not present; exact-match check not run (checks 1, 2, 5, 6 still apply)"
else
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

    # A tagged variable is searched unconditionally. None of the exemptions
    # below may apply to it: every one of them is a rule about what CANNOT be
    # host-specific, and the tag is a standing statement that this one is.
    if [[ -z "${HOST_SPECIFIC[$key]-}" ]]; then
      # Identical to the shipped example: a default, not a host value.
      [[ "${EXAMPLE_VAL[$key]-$'\x01'}" != "$val" ]] || continue
      # Retired: the code overwrites it, and its old value is the old
      # repo-defined segment that docs and the regression test still cite.
      [[ -z "${RETIRED[$key]-}" ]] || continue
      # Too short or purely numeric: cannot identify a host and would only
      # produce noise. Node counts, memory sizes and timeouts live here.
      (( ${#val} >= 4 )) || continue
      [[ ! "$val" =~ ^[0-9]+$ ]] || continue
    fi

    # Search the whole value, and for a tagged variable also each @-separated
    # part of it. `user@host` leaks just as badly one half at a time, and the
    # half that is an address is the half check 5 already covers.
    needles=("$val")
    if [[ -n "${HOST_SPECIFIC[$key]-}" && "$val" == *@* ]]; then
      while IFS= read -r part; do
        (( ${#part} >= 4 )) && needles+=("$part")
      done < <(printf '%s\n' "${val//@/$'\n'}")
    fi

    checked=$((checked + 1))
    for needle in "${needles[@]}"; do
      if hits="$(git grep -I -F -l -e "$needle" -- "${SCAN_FILES[@]}" 2>/dev/null | paste -sd' ' -)" \
         && [[ -n "$hits" ]]; then
        # Print the variable name and the files. Never the value itself.
        exact_hits=$((exact_hits + 1))
        finding "value of $key from $ENV_FILE appears in: $hits"
        break
      fi
    done
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || true)

  (( exact_hits > 0 )) \
    || pass "$checked host-specific value(s) checked, none found in tracked files"
fi

# ---------------------------------------------------------------------------
# Check 5 — IPv4 allowlist
# ---------------------------------------------------------------------------
section "check 5: only allowlisted IPv4 literals in tracked files"

# Allowed: the three fixed, repo-defined /22 lab segments; loopback and wildcard
# addresses; common netmasks; and the three RFC 5737 documentation ranges.
ip_allowed() {
  case "$1" in
    10.4[0-9].*|10.50.*)                       return 0 ;;  # repo-defined lab segments
    127.0.0.1)                                 return 0 ;;
    0.0.0.0)                                   return 0 ;;
    255.255.252.0|255.255.255.0|255.255.255.255|255.255.0.0) return 0 ;;
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
# Check 6 — MAC addresses must be locally administered
# ---------------------------------------------------------------------------
section "check 6: only locally-administered MAC addresses in tracked files"

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
