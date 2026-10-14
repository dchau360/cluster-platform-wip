#!/bin/bash
#
# cluster-pull — one self-configuration run of a compute node.
#
# Delivered by the cluster-pull Warewulf runtime overlay, with
# /etc/cluster-pull/pull.env beside it. Run by cluster-pull.service at boot and
# by cluster-pull.timer after that. Nothing configures the node over SSH, and
# it holds no credential: it clones the pinned ref from the head node's read-only mirror
# and reports through the head-node API, which knows it by its address.
#
# ansible-pull clones, then runs local.yml, which reports its own result. If
# ansible-pull fails before the play runs (the mirror is unreachable, the ref
# is missing), nothing on the node has changed: the previous checkout and the
# running services are untouched, which is the last-known-good state. That run
# is still reported, as `failed` with the fetch as the failed step, so a node
# that cannot reach its mirror is visible in NetBox and not merely quiet.

set -uo pipefail

# shellcheck source=/dev/null
source /etc/cluster-pull/pull.env

: "${CLUSTER_PULL_URL:?}" "${CLUSTER_PULL_REF:?}" "${CLUSTER_NODE_API:?}"
CLUSTER_PULL_DIR="${CLUSTER_PULL_DIR:-/var/lib/cluster-pull/checkout}"
CLUSTER_PULL_PLAYBOOK="${CLUSTER_PULL_PLAYBOOK:-ansible/local.yml}"

CLUSTER_PULL_STARTED="$(date +%s.%N)"
CLUSTER_PULL_RUN_ID="${INVOCATION_ID:-$(cat /proc/sys/kernel/random/uuid)}"
export CLUSTER_NODE_API CLUSTER_PULL_STARTED CLUSTER_PULL_RUN_ID
mkdir -p /run/cluster-pull "$(dirname "$CLUSTER_PULL_DIR")"
marker="/run/cluster-pull/reported-${CLUSTER_PULL_RUN_ID}"

echo "cluster-pull: run ${CLUSTER_PULL_RUN_ID} ref ${CLUSTER_PULL_REF} from ${CLUSTER_PULL_URL}"

# -C pins the ref. --full keeps a real clone so `git rev-parse` reports the
# commit applied. -i localhost, -c local: the node configures itself only.
ansible-pull \
  --url "$CLUSTER_PULL_URL" \
  --checkout "$CLUSTER_PULL_REF" \
  --directory "$CLUSTER_PULL_DIR" \
  --full \
  --inventory localhost, \
  "$CLUSTER_PULL_PLAYBOOK"
rc=$?

if (( rc != 0 )) && [[ ! -e "$marker" ]]; then
  sha="$(git -C "$CLUSTER_PULL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  ref="$(cat /etc/cluster-lab/image-reference 2>/dev/null || echo unknown)"
  tag="${ref##*:}"
  now="$(date +%s.%N)"
  duration="$(awk -v a="$CLUSTER_PULL_STARTED" -v b="$now" 'BEGIN{printf "%.3f", b-a}')"
  body="$(printf '{"result":"failed","git_sha":"%s","image_tag":"%s","duration_seconds":%s,"finished_at":"%s","run_id":"%s","failed_task":"%s"}' \
    "$sha" "${tag:-unknown}" "$duration" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$CLUSTER_PULL_RUN_ID" "fetch ${CLUSTER_PULL_REF} from mirror (exit ${rc})")"
  echo "cluster-pull: ansible-pull exited ${rc} before the play reported; nothing was applied"
  curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$body" "${CLUSTER_NODE_API}/v1/self/convergence" >/dev/null \
    && echo "cluster-pull: reported failed run to NetBox" \
    || echo "cluster-pull: could not reach the node API either; the stale-convergence alert covers this"
fi

rm -f "$marker"
exit "$rc"
