#!/usr/bin/env bash
#
# "Nothing knows the number 4."
#
# Node count is a variable everywhere. `N=2` and `N=4` must both work with
# no code change. That is easy to honour on day one and easy to lose by
# accident on day forty, so it is a CI gate rather than a convention.
#
# Three checks:
#
#   1. NODE_COUNT is assigned a literal in exactly one place: the example
#      env file, where it is the documented default.
#   2. No loop in the repo counts to a literal bound.
#   3. No hardcoded node-name list.

set -euo pipefail

# Needs bash 4 (mapfile, associative arrays). Say so plainly: a gate that dies
# with "mapfile: command not found" looks broken rather than unsupported.
# macOS ships bash 3.2; use `brew install bash`.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi
cd "$(git rev-parse --show-toplevel)"

ENV_EXAMPLE=lab/local.env.example
findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }
pass()    { printf 'ok   %s\n' "$*"; }

mapfile -t FILES < <(git ls-files | grep -vFx "$ENV_EXAMPLE" || true)
if [[ ${#FILES[@]} -eq 0 ]]; then echo "no tracked files to scan"; exit 0; fi

echo "== check 1: NODE_COUNT is never assigned a literal outside $ENV_EXAMPLE"
hits="$(git grep -I -n -E '^[^#]*\bNODE_COUNT[[:space:]]*=[[:space:]]*[0-9]+' -- "${FILES[@]}" || true)"
if [[ -n "$hits" ]]; then
  while IFS= read -r line; do finding "literal NODE_COUNT assignment: $line"; done <<<"$hits"
else
  pass "NODE_COUNT is only ever read, or defaulted in $ENV_EXAMPLE"
fi

echo
echo "== check 2: no loop counts to a literal bound"
# `seq 1 4`, `seq 4`, `{1..4}`, `range(1, 5)` and `for i in 1 2 3 4`.
hits="$(git grep -I -n -E '^[^#]*(seq[[:space:]]+[0-9]+[[:space:]]+[0-9]+|seq[[:space:]]+[0-9]+[[:space:]]*[;)|]|\{1\.\.[0-9]+\}|range\([[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*[0-9]+)' \
  -- "${FILES[@]}" || true)"
if [[ -n "$hits" ]]; then
  while IFS= read -r line; do finding "literal loop bound: $line"; done <<<"$hits"
else
  pass "every node loop is bounded by a variable"
fi

echo
echo "== check 3: no hardcoded node-name list"
# Two or more node names on one line, separated by anything.
prefix="$(grep -E '^NODE_NAME_PREFIX=' "$ENV_EXAMPLE" | cut -d= -f2)"
prefix="${prefix:-cn}"
hits="$(git grep -I -n -E "\\b${prefix}[0-9]{2}\\b[^0-9a-zA-Z]+\\b${prefix}[0-9]{2}\\b" -- "${FILES[@]}" || true)"
if [[ -n "$hits" ]]; then
  while IFS= read -r line; do finding "hardcoded node list: $line"; done <<<"$hits"
else
  pass "no hardcoded node-name list"
fi

echo
if (( findings > 0 )); then
  echo "RESULT: $findings finding(s). Node count must stay a variable."
  exit 1
fi
echo "RESULT: node count is a variable everywhere"
