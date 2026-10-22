# Playbooks

One operator, human or agent, with one playbook per job. A playbook says
what the job is, which tools to use, and what done looks like. Reading a
playbook should be enough to do the job without asking anyone.

| Job | Playbook |
|---|---|
| Any change to this repo, from issue to merged and running on the lab | [change-the-platform.md](change-the-platform.md) |
| Work on the lab host: get in, check it is safe, leave it clean | [lab-session.md](lab-session.md) |
| A node or cluster defect: reproduce, fix, prove on real nodes | [fix-a-cluster-defect.md](fix-a-cluster-defect.md) |
| Access is missing: GitHub, the lab host, or the AI account | [blocked-on-access.md](blocked-on-access.md) |
| A new or changed node image, from `cluster-images-wip` to every node | [image-release.md](image-release.md) |
| A real machine the lab did not create joins as a compute node | [add-a-machine.md](add-a-machine.md) |

[toolbox.md](toolbox.md) lists every approved tool: make targets, scripts,
gates and docs. [lessons.md](lessons.md) records every playbook fix and the
mistake behind it. `CLAUDE.md` and `AGENTS.md` at the repo root send any
agent here first. `make check-playbooks` keeps the toolbox and the Done when
lists complete.

## What the platform is for

The owner's definition of done for the whole project (interview, round 1):
a deployed cluster that can be tested and used as if it were production.
The owner can add nodes and inventory items by hand, and there are runbooks
for how to use each part. Every playbook serves one of these:

- **Deployed and usable like production.** `make up` brings it up, and
  `make acceptance` and `make slurm-ready` pass on it.
- **Nodes and inventory added by hand.** NetBox is the inventory.
  [add-a-machine.md](add-a-machine.md) covers a real machine, and
  `docs/operations.md` "Add a machine" covers a lab node.
- **Runbooks.** `docs/operations.md` is the operator runbook, one section
  per task, with the alert runbooks at the end. When an operator step
  changes, that doc changes in the same PR.

## Who merges

The operator merges its own PR once every item on the playbook's
**Done when** list passes and CI is green. No separate sign-off. The
handoff on the issue shows the checklist output, so the owner can audit
afterwards.

## The four rules

1. **Interview before a new kind of job.** If a job has no playbook, the
   operator asks the owner questions until they could do the job alone. The
   answers become a new playbook here before the work starts.
2. **Use the toolbox before building anything.** Look in
   [toolbox.md](toolbox.md) first. If a script, target or doc already does it,
   use it. If you build something new and it is approved (merged), add it to
   the toolbox in the same PR, and name the playbook step that uses it.
3. **Check your own work before you hand it over.** Every playbook ends with
   a **Done when** checklist. Run each item and paste its output into the
   handoff. If an item cannot run, say which one and why. Never mark it done.
4. **Fix the playbook, not the chat.** When the operator gets something
   wrong, the correction goes into the playbook (or the toolbox, or a gate),
   in a PR, with a line in [lessons.md](lessons.md). A correction made only in
   a conversation is lost when that conversation ends.

## Writing a playbook

Copy this shape. Keep it short. A step is one command or one decision.

```
# <Job>
When to use it: <trigger>
Inputs: <what you need before starting>
## Steps
1. ...
## Done when
- [ ] <check> -> <command that proves it>
## Known traps
- <trap> (see lessons.md: <date>)
```

These files are public like the rest of the repo, so the hygiene gates apply.
No host-specific values, no home-LAN addresses, no literal node counts or
node lists: write `<node>` and `N=<n>`.
