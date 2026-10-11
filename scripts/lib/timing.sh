#!/usr/bin/env bash
# shellcheck shell=bash
#
# Phase timing.
#
# The measured 1-to-N curve is a project deliverable, so timing is not a
# debug aid bolted on later. It is written here once, and every later task
# records into it by wrapping its work in phase_begin / phase_end.
#
#   phase_begin image-build          # a whole-run phase
#   ...
#   phase_end   image-build
#
#   phase_begin dhcp-lease cn01      # a per-node phase
#   ...
#   phase_end   dhcp-lease cn01
#
# Records land in $LAB_TIMING_DIR/<run-id>.ndjson, one JSON object per line:
#
#   {"run":"...","n":2,"phase":"dhcp-lease","node":"cn01",
#    "start":1760000000.123,"end":1760000004.456,"seconds":4.333,"status":"ok"}
#
# NDJSON because it is append-only, crash-safe, and trivially convertible to
# CSV for the curve. `make timings` renders the current run.

set -euo pipefail

LAB_RUN_ID="${LAB_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
export LAB_RUN_ID

_timing_file() { printf '%s/%s.ndjson' "${LAB_TIMING_DIR:?LAB_TIMING_DIR unset}" "$LAB_RUN_ID"; }
_now() { date +%s.%N; }
_phase_key() { printf '%s\x1f%s' "$1" "${2:-}"; }

declare -A _PHASE_START=()

timing_init() {
  mkdir -p "$LAB_TIMING_DIR"
  : > "$(_timing_file)"
  log "timing run $LAB_RUN_ID -> $(_timing_file)"
}

phase_begin() {
  local phase="$1" node="${2:-}"
  mkdir -p "$LAB_TIMING_DIR"
  _PHASE_START["$(_phase_key "$phase" "$node")"]="$(_now)"
  printf '%s>>%s %s%s\n' "$_C_BLU" "$_C_RST" "$phase" "${node:+ [$node]}"
}

# phase_end <phase> [node] [status]
phase_end() {
  local phase="$1" node="${2:-}" status="${3:-ok}"
  local key; key="$(_phase_key "$phase" "$node")"
  local start="${_PHASE_START[$key]:-}"
  [[ -n "$start" ]] || { warn "phase_end without phase_begin: $phase ${node}"; return 0; }
  local end secs
  end="$(_now)"
  secs="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')"
  unset '_PHASE_START[$key]'

  printf '{"run":"%s","n":%s,"phase":"%s","node":"%s","start":%s,"end":%s,"seconds":%s,"status":"%s"}\n' \
    "$LAB_RUN_ID" "${NODE_COUNT:-0}" "$phase" "$node" "$start" "$end" "$secs" "$status" \
    >> "$(_timing_file)"

  printf '%s<<%s %s%s %ss\n' "$_C_BLU" "$_C_RST" "$phase" "${node:+ [$node]}" "$secs"
}

# Run a command as a timed phase. Records status=fail and re-raises on error.
# timed <phase> <node|""> -- cmd...
timed() {
  local phase="$1" node="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  phase_begin "$phase" "$node"
  if "$@"; then
    phase_end "$phase" "$node" ok
  else
    local rc=$?
    phase_end "$phase" "$node" fail
    return "$rc"
  fi
}

# Render one run, or the newest one, as a table plus a CSV sibling file.
timing_report() {
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    # Newest run, by mtime. find rather than ls so a run id can contain
    # anything a filesystem allows.
    file="$(find "$LAB_TIMING_DIR" -maxdepth 1 -name '*.ndjson' -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -f2- || true)"
  fi
  [[ -n "$file" && -f "$file" ]] || { echo "no timing data in $LAB_TIMING_DIR"; return 0; }

  echo "timing run: $(basename "$file" .ndjson)"
  echo
  printf '%-24s %-10s %10s %8s\n' PHASE NODE SECONDS STATUS
  printf '%-24s %-10s %10s %8s\n' ------------------------ ---------- ---------- --------
  sed -e 's/[{}"]//g' -e 's/,/\n/g' "$file" \
  | awk -F: '
      /^phase/  {phase=$2}
      /^node/   {node=($2==""?"-":$2)}
      /^seconds/{secs=$2}
      /^status/ {status=$2; printf "%-24s %-10s %10.3f %8s\n", phase, node, secs, status;
                 total+=secs; if (node!="-") {pernode[node]+=secs}}
      END {printf "\n%-24s %-10s %10.3f\n", "TOTAL", "-", total}'

  local csv="${file%.ndjson}.csv"
  {
    echo "run,n,phase,node,seconds,status"
    sed -e 's/[{}"]//g' "$file" \
    | awk -F, '{r=n=p=nd=s=st="";
        for(i=1;i<=NF;i++){split($i,kv,":");
          if(kv[1]=="run")r=kv[2]; else if(kv[1]=="n")n=kv[2];
          else if(kv[1]=="phase")p=kv[2]; else if(kv[1]=="node")nd=kv[2];
          else if(kv[1]=="seconds")s=kv[2]; else if(kv[1]=="status")st=kv[2]}
        print r","n","p","nd","s","st}'
  } > "$csv"
  echo
  echo "csv: $csv"
}
