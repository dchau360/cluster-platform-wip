# Operating this repo

This repo is run by one operator, human or agent, with one playbook per job.
Before any work, read [playbooks/README.md](playbooks/README.md) and follow it.
This file only points there. The rules live in the playbooks, not here.

1. **Find the playbook for the job** in the index in `playbooks/README.md`.
   If none fits, interview the owner until you could do the job alone, and
   write the answers up as a new playbook before you start.
2. **Look in [playbooks/toolbox.md](playbooks/toolbox.md) before you build
   anything.** Extend what is there. A new make target or script gets its
   toolbox row in the same PR. `make check-playbooks` fails without it.
3. **Run the playbook's Done when list before you hand anything over**, and
   paste each check's output. If an item cannot run, say which one and why.
4. **When you get something wrong, fix the playbook, not the chat.** Put the
   correction in a playbook, the toolbox or a gate, in a PR, with an entry in
   [playbooks/lessons.md](playbooks/lessons.md).

The repo is public. No host-specific values, home-LAN addresses, literal node
counts or node lists in any tracked file, this one included. `make lint` checks.
