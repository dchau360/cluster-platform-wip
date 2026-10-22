# Add a real machine

When to use it: a physical or external machine, one the lab did not create,
has to join the cluster as a compute node. For a lab VM, use
`make nodes-up N=<n>` instead (see `docs/operations.md`, "A node in the lab").

Inputs: the machine's provisioning-NIC MAC, its serial if known, a rack
position, network boot enabled in its firmware, and a lab session
([lab-session.md](lab-session.md)).

## Steps

1. **Add it to NetBox first.** NetBox is the inventory; nothing else is
   edited. Create a device: site `lab`, role `Compute`, rack and position,
   serial. Add its provisioning NIC as an interface with the real MAC as the
   primary MAC. Matching is by MAC, so discovery adopts this record rather
   than creating a second one.
2. **Render from the record:** `make converge`. That writes the DHCP
   reservation and the Warewulf node definition from NetBox.
3. **Check the rendering** before you power anything:
   `sudo wwctl node list -a <node>` shows the node with that MAC.
4. **Boot it into discovery.** Set it to network boot and power it on, from
   its own BMC or front panel. It scrapes its own hardware, updates its
   NetBox record and claims its IPAM addresses.
5. **Let it burn in.** The device arrives `staged`, runs burn-in and posts
   its measurements. Do not change its status by hand.
6. **Promote it:** `make nodes-activate`. The gate is the only writer of
   status. If it fails, follow the `BurnInFailed` runbook in
   `docs/operations.md`.
7. **Bring it into Slurm:** `make reconfigure`, then `make slurm-ready`.

## Done when

- [ ] One NetBox device for the machine, not two -> search NetBox by its MAC and serial
- [ ] Discovery facts filled in (CPU, memory, NICs, disks) on that device
- [ ] Device status `active` -> set by `make nodes-activate`, not by hand
- [ ] Node converged -> `make convergence-status` exits 0 and lists it
- [ ] A job runs on it -> `make slurm-ready` exits 0 with the node included
- [ ] No host file, inventory list or playbook was edited for this machine -> `git status --short` is empty

## Known traps

- No hostname, MAC, serial or address of a real machine goes into this repo.
  They live in NetBox only. `make check-host-values` fails on them.
- `scripts/redfish.sh` drives the lab's emulated BMCs (libvirt domains)
  only. It cannot power a real machine. Use the machine's own BMC.
- A device created without the real MAC is not matched. Discovery then
  creates a second device, and you have two records for one machine.
