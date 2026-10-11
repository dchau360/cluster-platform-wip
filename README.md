# cluster-platform-wip

Work in progress. A small HPC-style cluster, provisioned from bare metal
upward on a single workstation: an isolated provisioning segment, UEFI PXE
boot, Warewulf-managed node images, NetBox as the source of truth, and
Slurm on top.

This repository holds the **platform**: the network, the provisioning
services, the automation and the measurement harness. Node images live in
[`cluster-images-wip`](https://github.com/dchau360/cluster-images-wip).

> This repository is **public**. Every commit is world-readable forever.
> Read [Repository rules](#repository-rules) before your first commit.

## Quick start

```sh
cp lab/local.env.example lab/local.env   # fill in the host-specific values
make up                                  # bring the platform up, idempotent
make demo N=2                            # start 2 nodes, print the timings
make demo N=4                            # same code, 4 nodes
make down                                # stop the lab
```

`make help` lists everything.

## What is here today

The foundation, and nothing above it. The floor is finished so the rest of
the work has somewhere to land.

| Working now | Where |
| --- | --- |
| Isolated provisioning bridge, no route to the home LAN | `scripts/net-up.sh` |
| dnsmasq bound to that bridge only, DHCP + TFTP | `scripts/net-up.sh` |
| UEFI/OVMF nodes on the segment, created and destroyed by the harness | `scripts/nodes-up.sh` |
| `make up` / `make down` / `make demo N=<n>`, idempotent | `Makefile` |
| Per-phase, per-node timing, NDJSON plus CSV | `scripts/lib/timing.sh` |
| Every lab service a systemd unit enabled at boot | `systemd/` |
| Repo hygiene gates, green before any content existed | `.github/workflows/ci.yml` |

Stubbed, owned by later tasks:

| Next | Where it lands |
| --- | --- |
| GRUB/kernel handoff over TFTP | `scripts/`, `ansible/roles/pxe/` |
| Warewulf server, node profiles, per-node overlays | `ansible/roles/warewulf/` |
| NetBox as source of truth, inventory generated from it | `ansible/roles/netbox/` |
| Slurm controller and compute roles, Munge from overlay | `ansible/roles/slurm/` |
| The measured 1-to-N curve | `docs/measurements.md` |

## Structure

```text
Makefile                      up / down / demo N=<n>, and every gate
lab/
  local.env.example           every host-specific variable, named and documented
  local.env                   the real values. UNTRACKED. never commit this.
scripts/
  up.sh down.sh demo.sh       the harness entry points
  preflight.sh                tool, KVM, firmware and systemd checks
  net-up.sh net-down.sh       the isolated provisioning segment and dnsmasq
  nodes-up.sh nodes-down.sh   UEFI nodes on the segment
  systemd-install.sh          render and install the units
  status.sh                   units, segment, nodes, leases on one screen
  verify-isolation.sh         prove the segment cannot reach the home LAN
  verify-idempotent.sh        prove a second 'make up' changes nothing
  cold-start-check.sh         prove every unit is enabled at boot
  check-no-host-values.sh     the leak gate. also runs in CI.
  check-node-count-is-variable.sh
  lib/common.sh               config loading, change accounting, primitives
  lib/timing.sh               phase_begin / phase_end / timing_report
systemd/
  lab.target.in               one handle for the whole lab
  lab-net.service.in          the segment, at boot
  lab-dnsmasq.service.in      DHCP, DNS and TFTP, on the segment only
ansible/
  site.yml                    top-level play, asserts the invariants
  group_vars/all.yml          node count and segment, as variables
  inventory/lab.yml           control host. compute nodes are generated.
  roles/                      pxe, warewulf, netbox, slurm land here
docs/
  architecture.md             how the pieces fit
  lab-host-setup.md           what the lab host needs, and why
  network-isolation.md        the isolation design and how it is proven
  measurements.md             the 1-to-N curve
```

## Design decisions worth knowing

**The provisioning segment has no uplink.** `br-prov` is a Linux bridge
with no port except node taps. There is no path to the home LAN by
construction. Three further measures make that enforced rather than
habitual: IP forwarding off on the interface, an nftables table of our own
that drops anything forwarded into or out of the bridge, and dnsmasq bound
to the bridge address with `bind-interfaces`. `make verify-isolation`
proves it from inside the segment, using a network namespace configured the
way a node would be. See [`docs/network-isolation.md`](docs/network-isolation.md).

**Reconcile, do not rebuild.** Every harness action reports `ok` when the
system is already correct and `changed` only when it had to act. `make up`
ends with `RESULT: changed=N`, and `make verify-idempotent` fails the build
if a second run changes anything.

**Cold start is a tested path.** A Windows reboot or `wsl --shutdown` stops
everything in the distribution. Every lab service is therefore a systemd
unit enabled at boot, and `make cold-start-check` asserts it.

**Timing is built in, not added later.** The measured 1-to-N curve is a
deliverable, so `phase_begin` / `phase_end` were written before the phases
existed. Later work records into the same NDJSON stream and the table grows
with it.

**Nothing knows the node count.** `N` is a variable everywhere. CI fails
on a literal `NODE_COUNT` assignment, a literal loop bound, or a hardcoded
node-name list.

## Repository rules

Non-negotiable. CI enforces all but the last.

1. **This repository is public.** Every commit is world-readable forever.
2. **No host-specific value in a tracked file.** Not an address on the home
   LAN, not an SSH username, not a real MAC. Those live in `lab/local.env`,
   which is untracked. The repository ships `lab/local.env.example` with
   every variable named and documented. Example MACs are synthetic, from
   the locally-administered range, so they can never identify real
   hardware. The `host-values` CI job fails if a value from `local.env`
   appears in a tracked file, if a non-allowlisted IPv4 literal appears
   anywhere, or if a globally-unique MAC appears anywhere.
3. **No secret in git.** The Munge key, SSH host keys and TLS material come
   from Warewulf per-node overlays at boot. The `gitleaks` job scans the
   working tree and the full history; GitHub secret-scanning push
   protection refuses a credential at `git push`.
4. **No lab state in git.** No qcow2, no TFTP tree, no NetBox dump, no
   `*.retry`. All of it lives under `LAB_STATE_DIR`, outside the repo.
5. **Nothing knows the node count.**
6. **Every phase is timed, per node, and recorded.**
7. **DHCP and TFTP never run on an interface that can reach the home LAN.**

Run the same gates CI runs before you push:

```sh
make lint          # host values, gitleaks, yamllint, ansible-lint, shellcheck
make verify        # isolation and idempotency, on the lab host
```

## Licence

Not yet chosen. Treat as all rights reserved until it is.
