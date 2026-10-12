#!/usr/bin/env bash
#
# The identity boundary across all of git history, not just the tracked tip.
#
# `check-no-tracked-secrets.sh` reads `git ls-files`, so it answers "is key
# material in the current tree?". That is the wrong question for a clone that
# will be public forever: a key added and removed is still a key in the pack
# file, reachable from the reflog and from every branch that ever carried it.
#
# This walks every object reachable from any ref plus the reflog and fails if
# a path shaped like identity material ever existed. Names, not contents: the
# build generates the Munge key and the SSH host keys on the lab host and
# delivers them through a Warewulf overlay, so no path with these shapes has
# a legitimate history here.
#
# Usage:  scripts/check-no-identity-in-git.sh
# Exit:   0 clean, 1 findings.

set -euo pipefail

# Needs bash 4 (mapfile). Say so plainly: a gate that dies with
# "mapfile: command not found" looks broken rather than unsupported.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "error: not a git repository" >&2
  exit 2
}

findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }
pass()    { printf 'ok   %s\n' "$*"; }

FORBIDDEN_NAMES=(
  'munge\.key$'
  'ssh_host_.*'
  'id_rsa($|\.)'
  'id_ed25519($|\.)'
  'id_ecdsa($|\.)'
  '\.pem$'
  '\.p12$'
  '\.jks$'
  '\.key$'
  '\.vault$'
)

# Every path that has ever been an object, de-duplicated. `--all` covers every
# ref, `--reflog` covers commits no branch points at any more. A commit object
# has no path in this output, so only lines with a path are kept.
mapfile -t HISTORIC_PATHS < <(
  git rev-list --objects --all --reflog 2>/dev/null \
    | sed -n 's/^[0-9a-f]\{40,\} //p' \
    | sort -u
)

echo "== scanning ${#HISTORIC_PATHS[@]} historical path(s)"

for pat in "${FORBIDDEN_NAMES[@]}"; do
  for f in "${HISTORIC_PATHS[@]}"; do
    if [[ "$f" =~ $pat ]]; then
      finding "identity-shaped path in git history matches /$pat/: $f"
    fi
  done
done

if (( findings == 0 )); then
  pass "no identity-shaped path exists in any git object"
  echo "RESULT: no identity material in git history"
  exit 0
fi

echo "RESULT: $findings finding(s). Identity material is generated on the lab host and delivered by a Warewulf overlay; it never belongs in git, including history."
exit 1
