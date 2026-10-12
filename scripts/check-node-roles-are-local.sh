#!/usr/bin/env bash
#
# Node-local roles stay node-local.
#
# The roles a compute node runs on itself (ansible-pull, local.yml) use no
# `delegate_to` and never read another host's `hostvars`. That single
# constraint is what lets one role set serve both pull and push: a role that
# reaches for another host only works where that host is in the inventory,
# and under ansible-pull the inventory is the node alone.
#
# The role list is read from local.yml itself, so a role added there is
# checked without editing this script.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLAY=ansible/local.yml
findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }

mapfile -t ROLES < <(sed -n 's/^[[:space:]]*name:[[:space:]]*\([a-z_][a-z0-9_]*\)[[:space:]]*$/\1/p' "$PLAY" | sort -u)
(( ${#ROLES[@]} > 0 )) || { echo "error: no roles found in $PLAY" >&2; exit 2; }
echo "node-local roles (from $PLAY): ${ROLES[*]}"

paths=("$PLAY")
for role in "${ROLES[@]}"; do
  [[ -d "ansible/roles/$role" ]] || { finding "$PLAY includes '$role', which has no ansible/roles/$role"; continue; }
  paths+=("ansible/roles/$role")
done

# delegate_to / local_action / run_once: work done on, or for, another host.
# hostvars[...]: reading another host. The node's own facts are ansible_facts.
pattern='^[^#]*(\bdelegate_to\b|\blocal_action\b|\brun_once\b|\bdelegate_facts\b|\bhostvars\b|\bgroups\[)'
hits="$(git grep -I -n -E "$pattern" -- "${paths[@]}" || true)"
if [[ -n "$hits" ]]; then
  while IFS= read -r line; do finding "$line"; done <<<"$hits"
fi

if (( findings > 0 )); then
  printf '\n%d finding(s). Node-local roles must not reach another host.\n' "$findings"
  exit 1
fi
echo "ok   no delegate_to, local_action, run_once or hostvars in ${#ROLES[@]} node-local role(s)"
