#!/usr/bin/env bash
#
# Run one day-2 play from the head node, timed.
#
#   scripts/day2.sh <play> [ansible-playbook args...]
#
# <play> is a file in ansible/playbooks/day2 without `.yml`: drain, resume,
# reconfigure, rolling_update, burnin_gate. Each node's phases land in the
# same NDJSON stream as every other measured phase.

export LAB_SCRIPT_NAME=day2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
lab_load_env

play="${1:?usage: day2.sh <drain|resume|reconfigure|rolling_update|burnin_gate> [args]}"
shift
book="$REPO_ROOT/ansible/playbooks/day2/${play}.yml"
[[ -f "$book" ]] || die "no day-2 play '$play' ($book)"

timing_init
export LAB_RUN_ID LAB_TIMING_DIR NODE_COUNT
rc=0
( cd "$REPO_ROOT/ansible" && timed "day2-${play}" "" -- ansible-playbook -i inventory/lab.yml "$book" "$@" ) || rc=$?
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"
exit "$rc"
