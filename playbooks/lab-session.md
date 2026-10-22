# Lab session

When to use it: before any command on the lab host, and when you leave it.

Inputs: SSH access to the lab host, then the WSL user that runs the lab
(see `lab/README.md` and `docs/lab-host-setup.md`).

## Steps

1. **Get in.** If SSH is refused, stop and follow
   [blocked-on-access.md](blocked-on-access.md). Do not try more keys or
   accounts.
2. **Check that nobody else is using it.** `make status`, and check that no
   drill, demo or `srun` is running (`squeue`, `pgrep -af 'make|drill'`). If
   something is running, wait or ask. Never cancel another job.
3. **Check the checkout.** `~/src/cluster-platform-wip` must be clean on
   `main`: `git status --short` prints nothing and `git log -1` matches
   `origin/main` after `git fetch`. If it is dirty, record the diff on the
   issue before you touch it.
4. **Check the cluster is up.** `make status`, then `sinfo`. Nodes down is
   normal after a host reboot: `make nodes-up N=<n>`. Don't treat it as a defect.
5. **Do the work.** Branch work runs from a scratch checkout
   ([change-the-platform.md](change-the-platform.md), step 6).
6. **Leave it clean.** The wip checkout is back on `main` and clean, scratch
   checkouts are removed, nodes are in the state you found them, and every
   temporary key or account you added is gone.

## Done when

- [ ] `git -C ~/src/cluster-platform-wip status --short` prints nothing
- [ ] `make status` shows the units and nodes as you found them, or as the issue requires
- [ ] No temporary key left: `grep -c <temp-key-comment> ~/.ssh/authorized_keys` returns 0
- [ ] Anything unexpected you found is written on the issue

## Known traps

- A temporary key added "just for a test" outlives the test. Remove it in
  the same session. (lessons.md: 2026-10-14)
- A lab checkout left on a branch, or with an uncommitted diff, makes the
  next session test the wrong code. (lessons.md: 2026-10-14)
