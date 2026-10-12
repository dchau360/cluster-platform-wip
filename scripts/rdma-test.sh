#!/usr/bin/env bash
#
# `make rdma-test` — a real RDMA bandwidth number from a node pair.
#
# What this is: Soft-RoCE. The `rdma_rxe` driver on each node presents its
# ordinary Ethernet NIC as an RDMA device, and `perftest` runs over it as it
# would over an HCA: queue pairs, registered memory, completion queues, RDMA
# WRITE and SEND on the wire. The verbs path is genuine.
#
# What this is not: InfiniBand hardware. There is no HCA, no hardware
# offload and no subnet manager anywhere in this lab. The host CPU builds and
# copies every packet, so the number below measures this software path on
# this host. It is not a prediction of what an HCA would report, and the
# write-up says so. See docs/rdma-soft-roce.md.
#
# How it runs the benchmark without logging in to a node: it does not log in.
# A compute node has no inbound SSH and holds no credential. The server and
# the client are two Slurm jobs, each pinned to one node of the pair, which is
# the same path any user's job would take.

export LAB_SCRIPT_NAME=rdma-test
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
lab_load_env

command -v srun >/dev/null 2>&1 || die "srun not found: this must run on the head node"

server_index="${RDMA_TEST_SERVER_INDEX}"
client_index="${RDMA_TEST_CLIENT_INDEX}"
(( server_index != client_index )) || die "the server and client indexes must differ"
if (( server_index > NODE_COUNT || client_index > NODE_COUNT )); then
  die "RDMA needs a pair: indexes ${server_index} and ${client_index} with NODE_COUNT=${NODE_COUNT}"
fi

server="$(node_name "$server_index")"
client="$(node_name "$client_index")"
server_ip="$(node_ip "$server_index")"

out_dir="$LAB_STATE_DIR/rdma"
sudo mkdir -p "$out_dir"
sudo chown "${LAB_WSL_USER:-${USER:-$(id -un)}}" "$out_dir"

log "pair: ${server} (server, ${server_ip}) and ${client} (client), device ${RDMA_DEVICE}"

# A node reports its own device, written by the rdma_soft_roce role. Reading
# it back is how this script knows the node agreed, rather than assuming.
phase_begin rdma-device
devices_ok=1
for name in "$server" "$client"; do
  if reported="$(srun --nodes=1 --nodelist="$name" --time=2 --chdir=/tmp \
                   cat /etc/cluster-lab/rdma-device 2>/dev/null)"; then
    ok "$name reports RDMA device: $(printf '%s' "$reported" | tr -d '\n')"
  else
    warn "$name has no /etc/cluster-lab/rdma-device; the rdma_soft_roce role has not run there"
    devices_ok=0
  fi
done
phase_end rdma-device "" "$( ((devices_ok == 1)) && echo ok || echo fail )"
(( devices_ok == 1 )) || die "the node pair has no RDMA device to benchmark"

echo
log "verbs device, as the node sees it"
srun --nodes=1 --nodelist="$server" --time=2 --chdir=/tmp \
  ibv_devinfo -d "$RDMA_DEVICE" | sed -n '1,12p'
echo

# ---------------------------------------------------------------------------
# The benchmark
# ---------------------------------------------------------------------------
#
# perftest is a server/client pair: the server listens, the client connects
# and drives the traffic, and the client prints the result table. Both halves
# are Slurm jobs, so the server has to be listening before the client starts
# and has to be cleaned up after. `--time` on each job is the backstop: a
# server whose client never arrived exits on its own rather than holding a
# node.

# RDMA_TEST_EXTRA_ARGS is unquoted on purpose: it is a list of perftest
# arguments, and quoting it would pass "-x 1" as one argument.
# shellcheck disable=SC2086
run_one() {
  local tool="$1"
  local server_log="$out_dir/${tool}.server.log"
  local client_log="$out_dir/${tool}.client.log"

  log "${tool}: ${RDMA_TEST_SIZE}-byte messages, ${RDMA_TEST_ITERS} iterations"

  srun --nodes=1 --nodelist="$server" --time="$(( (RDMA_TEST_TIMEOUT + 59) / 60 ))" \
       --chdir=/tmp --job-name="${tool}-server" \
       "$tool" -d "$RDMA_DEVICE" -s "$RDMA_TEST_SIZE" -n "$RDMA_TEST_ITERS" \
       ${RDMA_TEST_EXTRA_ARGS:-} \
       > "$server_log" 2>&1 &
  local server_job=$!

  # Wait for the listener. perftest prints nothing until the client connects,
  # so there is no banner to watch for; the only honest wait is for the
  # allocation to be running, then a short settle.
  local waited=0
  while (( waited < 60 )); do
    squeue --noheader --name="${tool}-server" --states=R --format='%i' 2>/dev/null | grep -q . && break
    sleep 1
    waited=$((waited + 1))
  done
  sleep 2

  local status=ok
  if ! srun --nodes=1 --nodelist="$client" --time="$(( (RDMA_TEST_TIMEOUT + 59) / 60 ))" \
         --chdir=/tmp --job-name="${tool}-client" \
         "$tool" -d "$RDMA_DEVICE" -s "$RDMA_TEST_SIZE" -n "$RDMA_TEST_ITERS" \
         ${RDMA_TEST_EXTRA_ARGS:-} \
         "$server_ip" > "$client_log" 2>&1; then
    status=fail
  fi

  wait "$server_job" 2>/dev/null || true
  scancel --name="${tool}-server" --quiet 2>/dev/null || true

  # perftest's result line, from the client's own table:
  #  #bytes #iterations  BW peak[MB/sec]  BW average[MB/sec]  MsgRate[Mpps]
  local result
  result="$(awk -v want="$RDMA_TEST_SIZE" '$1 == want && NF >= 5 { print; exit }' "$client_log" || true)"
  if [[ -z "$result" ]]; then
    status=fail
    warn "${tool}: no result line for a ${RDMA_TEST_SIZE}-byte message size"
    sed -n '1,30p' "$client_log" >&2
  else
    read -r _ iters peak average msgrate _ <<<"$result"
    printf '%-14s %10s iters  peak %10s MB/s  average %10s MB/s  %10s Mpps\n' \
      "$tool" "$iters" "$peak" "$average" "$msgrate"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tool" "$RDMA_TEST_SIZE" "$peak" "$average" "$msgrate" \
      >> "$out_dir/results.tsv"
  fi
  [[ "$status" == ok ]]
}

failures=0
for tool in $RDMA_TEST_TOOLS; do
  if timed "rdma-${tool}" "" -- run_one "$tool"; then :; else failures=$((failures + 1)); fi
done

echo
echo "logs and results: $out_dir"
if (( failures > 0 )); then
  die "${failures} RDMA benchmark(s) failed"
fi
echo "RDMA OK — a genuine verbs data path over Soft-RoCE (rdma_rxe), no InfiniBand hardware and no subnet manager"
