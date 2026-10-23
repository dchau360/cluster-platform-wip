#!/usr/bin/env bash
#
# The playbooks stay complete.
#
# Three checks, one per rule that a reader could otherwise forget:
#
#   - every documented make target is in playbooks/toolbox.md, so the
#     operator finds it before building a second one (rule 2);
#   - every playbook ends with a Done when checklist (rule 3);
#   - every playbook is in the index in playbooks/README.md, so the operator
#     can find the one for the job.
#
# A toolbox row may name a family of targets with a wildcard, as in
# `make drill-*`. Targets come from the `## ` help comments in the Makefile,
# the same list `make help` prints.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DIR=playbooks
TOOLBOX=$DIR/toolbox.md
INDEX=$DIR/README.md
# Not playbooks: the index, the toolbox and the lessons log.
NOT_PLAYBOOKS=" README.md toolbox.md lessons.md "

findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }

# Every documented make target is in the toolbox.
wildcards=$(grep -oE 'make [a-z][a-z0-9-]*-\*' "$TOOLBOX" | sed 's/^make //; s/\*$//' | sort -u || true)
targets=$(sed -n 's/^\([a-z][a-z0-9-]*\):.*## .*/\1/p' Makefile | sort -u)
[[ -n "$targets" ]] || { echo "error: no documented targets found in Makefile" >&2; exit 2; }
for t in $targets; do
  [[ "$t" == help ]] && continue
  grep -qE "make $t([^a-z0-9-]|$)" "$TOOLBOX" && continue
  covered=0
  for w in $wildcards; do
    [[ "$t" == "$w"* ]] && { covered=1; break; }
  done
  (( covered )) || finding "make $t is not in $TOOLBOX. Add its row and the playbook step that uses it"
done

# Every playbook has a Done when checklist and is in the index.
for f in "$DIR"/*.md; do
  name=$(basename "$f")
  [[ "$NOT_PLAYBOOKS" == *" $name "* ]] && continue
  if ! grep -q '^## Done when' "$f"; then
    finding "$f has no '## Done when' section"
  elif ! sed -n '/^## Done when/,/^## /p' "$f" | grep -q '^- \[ \] '; then
    finding "$f has a Done when section with no '- [ ]' items"
  fi
  grep -q "($name)" "$INDEX" || finding "$f is not linked from the index in $INDEX"
done

if (( findings )); then
  echo "$findings finding(s). See playbooks/README.md, 'The four rules'."
  exit 1
fi
echo "playbooks complete: every target in the toolbox, every playbook indexed and checkable"
