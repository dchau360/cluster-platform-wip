#!/usr/bin/env bash
#
# "Slurm-ready" — the end of the demo, and the only definition of done that
# matters.
#
# A node at a login prompt is not a cluster. This waits until every node this
# run booted has registered with slurmctld and reports a state that can take
# work, then runs a job array across all of them and checks the result. Both
# halves are measured: `slurm-join` per node, `job-array` for the run.
#
# Why a job array and not one `srun`: the acceptance criterion is that work
# lands on every node. An array of NODE_COUNT independent tasks, each asking
# for a whole node, is scheduled onto NODE_COUNT distinct nodes, so the union
# of the nodes the tasks ran on is the evidence. One job with N tasks would
# prove the allocation, not that each node ran something of its own.
#
# Why `scontrol` and not `sacct`: this cluster runs without an accounting
# database (AccountingStorageType is unset), so `sacct` has nothing to read.
# `scontrol show job` holds a finished job for MinJobAge seconds, which is
# where the per-task state, exit code and node list are read from.

export LAB_SCRIPT_NAME=slurm-ready
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
lab_load_env

command -v sinfo >/dev/null 2>&1 || die "sinfo not found: this must run on the head node"

# Slurm states that mean the node is registered and can be given work.
# `down`, `drain*` and `unknown` are not among them, and neither is `idle*`:
# the trailing star means slurmctld is not hearing from the node.
is_ready_state() {
  case "$1" in
    idle|mixed|allocated|alloc|completing) return 0 ;;
    *) return 1 ;;
  esac
}

# "<name> <state>" per node, with sinfo's state flag characters stripped.
node_states() {
  sinfo --noheader --Node --format='%N %T' 2>/dev/null \
    | awk 'NF >= 2 { gsub(/[*~#!%$@^+]+$/, "", $2); print $1, tolower($2) }'
}

# ---------------------------------------------------------------------------
# Phase 1: every node joins
# ---------------------------------------------------------------------------
#
# A node that is ready before the wait starts is recorded as `skip`, for the
# same reason the dhcp-lease phase skips an already-running node: the join it
# would measure happened in some earlier run, and reporting it as a fast join
# now would be a measurement of nothing. See docs/measurements.md.

declare -A PENDING=()
mapfile -t START_STATE < <(node_states)

for i in $(lab_node_indexes); do
  name="$(node_name "$i")"
  state=''
  for line in "${START_STATE[@]}"; do
    [[ "${line%% *}" == "$name" ]] && state="${line#* }"
  done
  if [[ -n "$state" ]] && is_ready_state "$state"; then
    phase_skip slurm-join "$name" "already $state; no new join to measure"
  else
    PENDING["$name"]=1
    phase_begin slurm-join "$name"
  fi
done

if (( ${#PENDING[@]} > 0 )); then
  log "waiting up to ${SLURM_READY_TIMEOUT}s for ${#PENDING[@]} node(s) to join Slurm"
  deadline=$(( $(date +%s) + SLURM_READY_TIMEOUT ))
  while (( ${#PENDING[@]} > 0 )) && (( $(date +%s) < deadline )); do
    while read -r name state; do
      [[ -n "${PENDING[$name]-}" ]] || continue
      if is_ready_state "$state"; then
        phase_end slurm-join "$name" ok
        ok "$name joined Slurm ($state)"
        unset 'PENDING[$name]'
      fi
    done < <(node_states)
    (( ${#PENDING[@]} == 0 )) || sleep 2
  done
fi

joined_all=1
for name in "${!PENDING[@]}"; do
  phase_end slurm-join "$name" fail
  warn "$name did not reach a usable Slurm state in ${SLURM_READY_TIMEOUT}s"
  joined_all=0
done

echo
sinfo --Node --long
echo

(( joined_all == 1 )) || die "not every node joined Slurm; no job array was run"

# ---------------------------------------------------------------------------
# Phase 2: a job array runs across all of them
# ---------------------------------------------------------------------------

expected=()
for i in $(lab_node_indexes); do expected+=("$(node_name "$i")"); done

phase_begin job-array
# --chdir: the submitting shell's directory does not have to exist on a node,
# and a diskless node's root is not the operator's home. Without it slurmd
# logs a chdir error per task, which reads like a failure and is not one.
#
# --exclusive: one task per node, which is what makes the union of the node
# lists below mean "every node ran a task of its own".
array_id="$(sbatch --parsable \
  --job-name="acceptance-array" \
  --array="1-${NODE_COUNT}" \
  --nodes=1 --ntasks=1 --exclusive \
  --chdir=/tmp --output=/dev/null \
  --time="${SLURM_ARRAY_TIME_LIMIT}" \
  --wrap "${SLURM_ARRAY_PAYLOAD}")"
log "job array ${array_id} submitted: ${NODE_COUNT} task(s), one node each"

deadline=$(( $(date +%s) + SLURM_ARRAY_TIMEOUT ))
while (( $(date +%s) < deadline )); do
  # squeue lists only pending and running work, so no lines for this job id
  # is the whole array having left the queue.
  remaining="$(squeue --noheader --array --job="$array_id" 2>/dev/null | wc -l)"
  (( remaining == 0 )) && break
  sleep 2
done

# Per-task state, exit code and node, from the controller's own record.
# `-o` puts each task on one line, which is what makes this parseable without
# tracking which key belongs to which record across lines.
record="$(scontrol -o show job "$array_id" 2>/dev/null || true)"
[[ -n "$record" ]] || { phase_end job-array "" fail; die "scontrol has no record of job $array_id"; }

printf '%-8s %-8s %-12s %-8s %s\n' TASK JOBID STATE EXIT NODE
tasks=0; completed=0; ran_on=()
while read -r taskid jobid state exitcode nodelist; do
  tasks=$((tasks + 1))
  printf '%-8s %-8s %-12s %-8s %s\n' "$taskid" "$jobid" "$state" "$exitcode" "$nodelist"
  [[ "$state" == COMPLETED && "$exitcode" == 0:0 ]] && completed=$((completed + 1))
  [[ -n "$nodelist" && "$nodelist" != "(null)" ]] && ran_on+=("$nodelist")
done < <(awk '{
    t = ""; j = ""; s = ""; e = ""; n = ""
    for (i = 1; i <= NF; i++) {
      if      ($i ~ /^ArrayTaskId=/) { split($i, a, "="); t = a[2] }
      else if ($i ~ /^JobId=/)       { split($i, a, "="); j = a[2] }
      else if ($i ~ /^JobState=/)    { split($i, a, "="); s = a[2] }
      else if ($i ~ /^ExitCode=/)    { split($i, a, "="); e = a[2] }
      else if ($i ~ /^NodeList=/)    { split($i, a, "="); n = a[2] }
    }
    if (t != "") { print t, j, s, e, n }
  }' <<<"$record")
echo

# The union of the nodes the tasks ran on, against the nodes this run has.
# `scontrol show hostnames` expands a Slurm range expression, so a task
# allocated more than one node cannot hide inside a bracketed list.
covered=()
if (( ${#ran_on[@]} > 0 )); then
  mapfile -t covered < <(printf '%s\n' "${ran_on[@]}" \
    | xargs -r -n1 scontrol show hostnames 2>/dev/null | sort -u)
fi

missing=()
for name in "${expected[@]}"; do
  printf '%s\n' ${covered[@]+"${covered[@]}"} | grep -qxF "$name" || missing+=("$name")
done

status=ok
if (( tasks != NODE_COUNT )); then
  warn "expected ${NODE_COUNT} array task(s), the controller recorded ${tasks}"
  status=fail
fi
if (( completed != tasks )); then
  warn "${completed}/${tasks} task(s) COMPLETED with exit 0:0"
  status=fail
fi
if (( ${#missing[@]} > 0 )); then
  warn "no array task ran on: ${missing[*]}"
  status=fail
fi
phase_end job-array "" "$status"

echo "array ${array_id}: ${completed}/${tasks} task(s) COMPLETED 0:0, across ${#covered[@]}/${NODE_COUNT} node(s)"
[[ "$status" == ok ]] || die "the job array did not run cleanly on every node"
echo "SLURM READY — ${NODE_COUNT} node(s) joined and a job array ran on every one of them"
