#!/usr/bin/env bash
#
# make convergence-status — which node is on which commit, and who is stale.
#
# One NetBox query. Each node's last pull run (commit, image tag, result,
# duration, when) is a custom field on its device, written by the node API on
# the node's behalf. Exit status is the alert: non-zero when a node's last run
# failed or is older than CONVERGENCE_STALE_SECONDS. Prometheus raises the
# same condition as ClusterNodeConvergenceStale.

export LAB_SCRIPT_NAME=convergence-status
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/netbox.sh
source "$HERE/lib/netbox.sh"
lab_load_env

STALE="${CONVERGENCE_STALE_SECONDS:-3600}"
deployed="$(git -C "$REPO_ROOT" ls-remote origin "refs/heads/${DEPLOYED_REF:-deployed}" 2>/dev/null | cut -c1-12)"

netbox_get '/api/dcim/devices/?role=compute&limit=0' \
  | python3 -c '
import json, sys, time, calendar
stale, deployed = float(sys.argv[1]), sys.argv[2]
now = time.time()
rows, bad = [], 0
for d in sorted(json.load(sys.stdin)["results"], key=lambda d: d["name"]):
    c = d.get("custom_fields") or {}
    stamp = c.get("last_converged_at")
    age = now - calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")) if stamp else None
    result = c.get("convergence_result") or "-"
    sha = (c.get("last_git_sha") or "-")[:12]
    flag = ""
    if d["status"]["value"] not in ("staged", "active", "failed"):
        flag = ""  # not expected to be running, so never stale
    elif age is None or age > stale:
        flag = "STALE"
    elif result != "success":
        flag = "FAILED"
    elif deployed and sha != deployed:
        flag = "behind"
    bad += flag in ("STALE", "FAILED")
    rows.append((d["name"], d["status"]["value"], sha, c.get("image_tag") or "-", result,
                 c.get("convergence_duration_seconds") or "-",
                 "never" if age is None else f"{int(age)}s ago", flag))
head = ("device", "status", "commit", "image", "result", "seconds", "last run", "")
w = [max(len(str(r[i])) for r in rows + [head]) for i in range(len(head))]
for r in [head] + rows:
    print("  ".join(str(v).ljust(w[i]) for i, v in enumerate(r)))
display_deployed = deployed or "unknown"
print(f"\ndeployed ref: {display_deployed}   stale after: {int(stale)}s")
sys.exit(1 if bad else 0)
' "$STALE" "$deployed"
