# Fix a cluster defect

When to use it: something on the head node or on the nodes does not behave
as the docs say. Then hand the fix to
[change-the-platform.md](change-the-platform.md).

## Steps

1. **Reproduce it on real nodes** and paste the exact command and output.
   Use the operator path the docs describe (for example `sudo -u hpc srun`),
   not root shortcuts.
2. **Find where it breaks.** Is the file or service missing on the head
   node, on the nodes, or on both? Nodes get files from three places, and the
   fix goes in the right one:
   - Warewulf overlays: identical on every node, rendered by
     `warewulf_server` on the head node.
   - `ansible-pull` node roles: node-local only. `make check-node-roles`
     forbids a node role from reaching another host.
   - The node image (`cluster-images-wip`).
3. **Write the issue:** Symptom, Cause, Fix, Done when. The Done when must
   include the reproduce command from step 1, now passing.
4. **Do not paper over it.** No `StrictHostKeyChecking=no`, no `chmod 777`,
   no disabled gate. If the honest fix is bigger, say so on the issue.
5. **Fix and prove it** with [change-the-platform.md](change-the-platform.md).
6. **Add a check** so it cannot come back unnoticed: a Python test, a gate
   in `scripts/check-*.sh`, an acceptance drill, or an alert rule. If none
   fits, say why on the issue.

## Done when

- [ ] The reproduce command from step 1 passes on the lab from `main`, output pasted
- [ ] The fix lands on every place that needs it (head node and nodes)
- [ ] It still works after a node reboot or `make nodes-up`, not just after converge
- [ ] A check exists that would have caught it, or the issue says why not
- [ ] Everything in [change-the-platform.md](change-the-platform.md) Done when

## Known traps

- Runtime overlays refresh without a reboot, system overlays don't. Know
  which one you changed before you say "fixed". (lessons.md: 2026-10-12)
- Never `chmod` a mounted share. It broke every pull after boot.
  (lessons.md: 2026-10-15)
