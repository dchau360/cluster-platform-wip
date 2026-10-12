#!/usr/bin/env bash
#
# make promote SHA=<commit>     — move the `deployed` ref to a commit.
#
# Nodes pull `deployed`, never `main`. Promoting a change is this one ref
# update; rolling back is the same command with the previous commit. The
# previous commit is printed every time so the rollback is always at hand.
#
# A commit is promotable only when CI ran on that exact commit and every job
# passed, including `pull check-mode`: local.yml run in --check inside the
# node image, with the node's own ansible-core. A commit that would break
# pull fails that job and this script refuses it. GitHub enforces the same
# rule server-side: `deployed` is a protected branch that requires the
# check, so a hand-typed `git push` of a red commit is rejected too.
#
# Then, on the lab host, the mirror is refreshed so nodes see the new ref on
# their next timer run instead of within the mirror's 5-minute cycle.

export LAB_SCRIPT_NAME=promote
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

REF="${DEPLOYED_REF:-deployed}"
REQUIRED_CHECK="${PROMOTE_REQUIRED_CHECK:-pull check-mode}"
SHA_IN="${SHA:-}"
[[ -n "$SHA_IN" ]] || die "set SHA to the commit to promote, e.g. make promote SHA=\$(git rev-parse origin/main)"

command -v gh >/dev/null 2>&1 || die "gh not found; promotion reads CI status from GitHub"

git fetch --quiet origin
sha="$(git rev-parse --verify "${SHA_IN}^{commit}")" || die "'$SHA_IN' is not a commit"
remote="$(git remote get-url origin)"
repo="$(sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##' <<<"$remote")"
previous="$(git rev-parse --verify --quiet "origin/$REF" || true)"

log "candidate ${sha:0:12} for $REF on $repo"
log "currently deployed: ${previous:0:12}${previous:+ }$(git log -1 --format=%s "$previous" 2>/dev/null || true)"

if [[ "$sha" == "$previous" ]]; then
  ok "$REF is already ${sha:0:12}"
  exit 0
fi

# Every check run on this exact commit, from GitHub.
runs="$(gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
          --jq '.check_runs[] | [.name, .status, (.conclusion // "none")] | @tsv')"
[[ -n "$runs" ]] || die "CI has not run on ${sha:0:12}. Push it to a branch and wait for CI."

printf '%s\n' "$runs" | awk -F'\t' '{printf "  %-24s %-11s %s\n", $1, $2, $3}'

awk -F'\t' -v n="$REQUIRED_CHECK" '$1 == n {f = 1} END {exit !f}' <<<"$runs" \
  || die "no '$REQUIRED_CHECK' run on ${sha:0:12}; it is required for $REF"
if awk -F'\t' '$2 != "completed" {exit 1}' <<<"$runs"; then :; else
  die "CI is still running on ${sha:0:12}; promote when it has finished"
fi
bad="$(awk -F'\t' '$3 != "success" && $3 != "skipped" && $3 != "neutral" {print $1" ("$3")"}' <<<"$runs")"
if [[ -n "$bad" ]]; then
  printf '%s\n' "$bad" | sed 's/^/  red: /' >&2
  die "REFUSED: ${sha:0:12} is not green. It never reaches $REF."
fi

git push --quiet --force-with-lease="$REF:${previous}" origin "$sha:refs/heads/$REF" \
  || die "push to $REF refused (protection, or $REF moved under us)"
changed "$REF ${previous:0:12} -> ${sha:0:12}"

# On the lab host, have the mirror publish it now.
if systemctl cat cluster-git-mirror.service >/dev/null 2>&1; then
  sudo systemctl start cluster-git-mirror.service && ok "head-node mirror refreshed"
fi

echo
echo "rollback: make promote SHA=${previous}"
