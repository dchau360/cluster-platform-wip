# Lessons

Every time the operator got something wrong, the fix went into a playbook,
the toolbox or a gate, not a chat. Newest first. One line for what went
wrong, one for what changed.

## 2026-10-22: playbooks introduced

The first entries below are taken from issues that came before the
playbooks existed.

## 2026-10-19: done on a branch is not done

Wrong: a fix was proven on a branch build, then sat unmerged for days while
`main` moved on by many PRs.
Changed: change-the-platform **Done when** requires merge, converge from
`main`, and the check run again from `main`.

## 2026-10-19: retrying missing access every run

Wrong: each run retried GitHub push and lab SSH, failed the same way, and
posted the same comment.
Changed: new playbook [blocked-on-access.md](blocked-on-access.md): confirm
once, ask once, finish the rest, mark the issue blocked.

## 2026-10-15: fix applied to the head node only

Wrong: cluster host keys were trusted on the head node only, so node-to-node
SSH as the job user failed with "Host key verification failed".
Changed: fix-a-cluster-defect step 2 asks where the file has to land
(overlay, node role or image), and Done when checks every place.

## 2026-10-15: chmod on a mounted share

Wrong: `shared_storage` changed the mode of a mounted share, and every pull
after boot failed.
Changed: listed as a trap in [fix-a-cluster-defect.md](fix-a-cluster-defect.md).

## 2026-10-14: temporary key and dirty lab checkout left behind

Wrong: a test key stayed in the lab user's `authorized_keys`, and the lab
checkout was left on an old commit with an uncommitted diff.
Changed: [lab-session.md](lab-session.md) checks the checkout on arrival and
requires a clean leave, with no temporary keys left.

## 2026-10-13: docs broke the node-count gate

Wrong: a docs line named a node pair, and `check-node-count-is-variable`
failed.
Changed: the playbook README says docs follow the same gates. Write `<node>`
and `N=<n>`.

## 2026-10-12: overlay change reported fixed before it reached the node

Wrong: a runtime-overlay change was assumed live; it had not refreshed.
Changed: fix-a-cluster-defect **Done when** requires the check after a node
reboot or `make nodes-up`, not just after converge.
