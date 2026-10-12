#!/usr/bin/env bash
#
# lab/local.env.example must be safe to source.
#
# Every harness script gets its configuration by sourcing the assignment lines
# out of this file (see lab_load_env in scripts/lib/common.sh). That makes an
# unquoted multi-word value not a typo but a command:
#
#   ACCEPTANCE_NODE_COUNTS=1 2 4
#
# sourced, runs `2 4` with ACCEPTANCE_NODE_COUNTS=1 in its environment. The
# failure surfaces as `line 64: 2: command not found` from a file descriptor,
# miles from the line that caused it, in whichever script happened to load
# the configuration first. This gate catches it where it was written.
#
# Two checks, because one of them explains the other:
#
#   1. The filtered stream actually sources, in a clean shell, with errexit.
#      That is the real proof.
#   2. Any value containing a character the shell acts on is quoted. That is
#      the readable rule, and it catches a value that would merely be split
#      rather than executed.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"
ENV_EXAMPLE=lab/local.env.example
[[ -f "$ENV_EXAMPLE" ]] || { echo "error: no $ENV_EXAMPLE" >&2; exit 2; }

findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }
pass()    { printf 'ok   %s\n' "$*"; }

echo "== check 1: the assignment lines source cleanly in a clean shell"
# `env -i` so nothing already in this shell's environment can make a broken
# line look fine — but PATH is kept, because the process substitution has to
# be able to find grep. Without it the substitution produces nothing, an
# empty file sources perfectly, and the gate reports a pass it did not earn.
# The same grep lab_load_env uses, so this tests the real stream rather than
# an approximation of it.
if out="$(env -i "PATH=$PATH" bash -euo pipefail -c '
    # shellcheck disable=SC1090
    source <(grep -E "^[A-Za-z_][A-Za-z0-9_]*=" "$1")' _ "$ENV_EXAMPLE" 2>&1)"; then
  pass "$ENV_EXAMPLE sources with no error"
else
  finding "$ENV_EXAMPLE does not source cleanly: ${out:-exit $?}"
fi

echo
echo "== check 2: a value the shell would act on is quoted"
unquoted=0
while IFS= read -r line; do
  key="${line%%=*}"
  value="${line#*=}"
  # A trailing `# ...` is a comment, as it is to the shell, so strip it
  # before judging the value. The example tags its host-specific variables
  # that way: `LAB_HOST_SSH=          # host-specific`.
  value="$(printf '%s' "$value" | sed -E 's/(^|[[:space:]])#.*$//; s/[[:space:]]+$//')"
  [[ -z "$value" ]] && continue
  case "$value" in
    \'*\'|\"*\") continue ;;
  esac
  # What is left is a bare word, and most values are exactly that. Anything
  # the shell would split on or act on has to be quoted.
  if [[ "$value" =~ [[:space:]\;\&\|\$\`\(\)\<\>] ]]; then
    unquoted=$((unquoted + 1))
    finding "$key has an unquoted value the shell would act on. Quote it."
  fi
done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_EXAMPLE")
(( unquoted > 0 )) || pass "every value is a bare word or quoted"

echo
if (( findings > 0 )); then
  echo "RESULT: $findings finding(s). The example env file is sourced by every script."
  exit 1
fi
echo "RESULT: $ENV_EXAMPLE is safe to source"
