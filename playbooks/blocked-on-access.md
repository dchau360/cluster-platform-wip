# Blocked on access

When to use it: a step needs access you don't have. That can be GitHub
push, SSH to the lab host, or the AI account running the operator.

## Steps

1. **Confirm it once.** Run the smallest command that proves it:
   `git ls-remote origin` for GitHub, `ssh -o BatchMode=yes <lab> true` for
   the lab. Paste the error. Do not cycle through every key or account.
2. **Ask once, in the right place.** Make one access request that names the
   exact access, the account, and the step it unblocks. If a request is
   already pending, don't open a second one. Link the pending one.
3. **Finish everything that doesn't need the access.** Commit locally, prove
   on the lab if you can, and write the exact remaining commands on the
   issue so the next run only has to run them.
4. **Mark the issue blocked** and name the request and its owner. Don't
   leave it "in progress" while you wait.
5. **When access returns,** check that the base hasn't moved under you
   (`git fetch` and `git merge-tree --write-tree origin/main <commit>`),
   then continue from the written remaining commands.

## Done when

- [ ] One access request exists and the issue links it
- [ ] The issue lists the exact remaining commands
- [ ] The issue status is blocked, with the owner named

## Known traps

- Retrying the same failed access every run fills the issue with noise and
  changes nothing. Retry only when the request is resolved.
  (lessons.md: 2026-10-19)
