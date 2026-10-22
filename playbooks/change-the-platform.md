# Change the platform

When to use it: any change to this repo, from an issue to a commit that is
merged, converged on the lab, and (for node roles) promoted.

Inputs: an issue with a **Done when** list, push access to GitHub, and a
lab session ([lab-session.md](lab-session.md)).

## Steps

1. **Read the issue's Done when.** If it has none, write one first and get
   it agreed. It becomes the handoff checklist.
2. **Check the toolbox.** Find the make targets, scripts and docs the change
   touches in [toolbox.md](toolbox.md). Extend those. Do not write a second
   script for the same job.
3. **Branch from current `main`, in a worktree.**
   `git fetch && git worktree add -b sre<NN>-<topic> ../cluster-platform-sre<NN> origin/main`.
   One worktree per issue. Remove it after the merge (step 10).
4. **Make the change.** Code, the doc that describes it
   (`docs/operations.md` for anything an operator runs), and the toolbox
   entry if you added a target or script.
5. **Run the gates:** `make lint`. Run it on the lab host from a scratch
   checkout of the branch (`~/src/cluster-platform-sre<NN>`), since several
   gates need bash 4 and `lab/local.env`. It must print rc=0.
6. **Prove it on the lab, from the scratch checkout:** `make converge`, then
   the issue's own check. Never test a branch from `~/src/cluster-platform-wip`.
   That checkout stays clean on `main`.
7. **Commit.** One commit per idea, with a message that says why. Your git
   identity must not change (`make git-identity` checks the history).
8. **Push and open a PR** against `main`. Wait for CI to go green. Then
   merge it yourself: the owner's rule is that the operator merges once the
   Done when items that can run before merge pass (see the README, "Who
   merges"). Paste their output in the PR description first.
9. **Bring the lab to `main`.** In `~/src/cluster-platform-wip`: `git pull`,
   then `make converge`. If `systemd/` changed, also `make systemd-install`.
   If a node role changed, `make promote SHA=<merge commit>`, then
   `make convergence-status`.
10. **Clean up, only after the merge.** First prove it merged:
    `gh pr view <n> --json state -q .state` prints `MERGED`. Anything else,
    stop: deleting the branch of an open PR closes it. Then remove the lab
    scratch checkout and the local worktree
    (`git worktree remove ../cluster-platform-sre<NN>`), and delete the
    merged branch.
11. **Hand off.** Post the Done when checklist on the issue with the output
    of each check.

## Done when

- [ ] `make lint` rc=0 on the merged commit -> CI green on the PR
- [ ] PR merged; `git log -1 origin/main` shows it
- [ ] Lab checkout clean on `main` at the merge -> `git -C ~/src/cluster-platform-wip status --short` prints nothing and `git log -1` matches
- [ ] `make converge` from `main` reports `failed=0`
- [ ] Node role changed: `make convergence-status` exits 0 after `make promote`
- [ ] The issue's own check passes on the lab from `main`, output pasted
- [ ] Toolbox and docs updated if a target, script or operator step changed
- [ ] Scratch checkout and worktree removed, after `gh pr view <n> --json state -q .state` printed `MERGED`

## Known traps

- "Merged" said in chat is not merged. Check the PR state before deleting
  anything. (lessons.md: 2026-10-22)
- A fix that works on the head node may not reach the nodes. Check where
  the file has to land. (lessons.md: 2026-10-15)
- Docs are scanned by the gates too: no node pair on one line, no literal
  node count. (lessons.md: 2026-10-13)
- Proving a branch is not done. It is done after merge, converge from
  `main`, and the check run again. (lessons.md: 2026-10-19)
