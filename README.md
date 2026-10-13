# cluster-platform-wip

**One command takes powered-off machines to an HPC cluster that runs a job on
every node.** No manual step anywhere in the middle: UEFI PXE boot, node images
served over the network, NetBox as the source of truth, nodes that configure
themselves, a hardware acceptance gate, and Slurm on top.

At four nodes that is **286 seconds end to end, measured** — and the same
command runs at any node count, because nothing in this repository knows one.

```sh
make demo N=4     # powered-off guests -> a Slurm cluster that has taken work
```

## Watch the demo

The live two-node run is committed as an asciinema cast, so a reader can
replay the real thing without downloading a video:

- [`docs/demo/make-demo-n2.cast`](docs/demo/make-demo-n2.cast) — the live
  `make demo N=2` (1:35). Read it as
  [`make-demo-n2.txt`](docs/demo/make-demo-n2.txt) if you would rather not
  install a player.
- [`docs/demo/timings-20261013T000455Z-686422.cast`](docs/demo/timings-20261013T000455Z-686422.cast)
  — the stored `N=4` timing table, reprinted.
- [`docs/demo/narration.md`](docs/demo/narration.md) — the five-minute
  narration, with closed captions in
  [`narration.srt`](docs/demo/narration.srt) and
  [`narration.vtt`](docs/demo/narration.vtt).

There is no narrated video; the captions are the narration.

## The problem this solves

Between a powered-off server and a compute node running someone's job there
is a pipeline most people never see: firmware, a DHCP offer, a TFTP fetch, an
iPXE script, a kernel and an initramfs, a root filesystem that arrives over
the network, an identity that must come from somewhere other than the image,
and a scheduler that has to be told the node exists.

This repository builds that pipeline, on one workstation, with every phase
timed per node so the cost of each step is a number rather than an opinion.
It is the **platform**: the network, the provisioning services, the automation
and the measurement harness. The node images are built and published by
[`cluster-images-wip`](https://github.com/dchau360/cluster-images-wip).

## What it proves, and what proves it

| Claim | Command | Evidence |
| --- | --- | --- |
| Powered-off to a cluster that takes work, no manual step | `make demo N=<n>` | `sinfo` idle, a job array with one task per node, all `COMPLETED 0:0` — [console output](docs/acceptance-drills.md#measured-results) |
| The same code at any node count | `make demo N=<a>` / `N=<b>` | per-phase tables at `N=1`, `2` and `4` — [the curve](docs/measurements.md#results) |
| Idempotent: a second run changes nothing | `make verify-idempotent` | head converge `ok=119 changed=0`, node pull `ok=38 changed=0`; the build fails otherwise |
| The provisioning segment cannot reach the home LAN | `make verify-isolation` | proven from inside the segment, in a namespace configured as a node — [design](docs/network-isolation.md) |
| A degraded node never joins the cluster | `make burnin-gate` | a disk throttled to 4 MiB/s against a 20 MiB/s floor was set `failed` — [drill](docs/acceptance-drills.md#the-burn-in-gate-holds-a-deliberately-failed-node) |
| A real RDMA bandwidth number, no IB hardware | `make rdma-test` | `ib_write_bw` 396.21 MB/s, `ib_send_bw` 480.11 MB/s over `rdma_rxe`; `iperf3` 64.3 Gbit/s on the same link |
| One node re-provisions while its neighbours keep running | `make drill-reprovision` | every neighbour's domain id unchanged and its QEMU CPU time still growing |
| Identity survives a NIC swap | `make drill-nic-swap` | hostname and NetBox device unchanged, MAC changed |
| Image rollback, and rollout that rolls itself back | `make rollback TAG=sha-<previous>` | the booted node reports the older tag; a rollout to a broken image stopped itself after one node |
| Configuration rollback in one ref move | `make promote SHA=<previous>` | **2.95 s measured**; every node converged on the commit the ref names |
| Cold-start recovery after the host restarts | `make cold-start-check` | every lab service is a systemd unit enabled at boot, and the drill proves the lab returns |
| No secret and no host value in git | `make lint` | `gitleaks` over the worktree and the full history, plus a host-value gate — [repository rules](#repository-rules) |

## The numbers

Measured on the lab host on 2026-10-13, platform `5ab1a81`, node image
`sha-baa648ba99c8`. Full tables in [`docs/measurements.md`](docs/measurements.md#results).

| | N=1 | N=2 | N=4 | Grows with N? |
| --- | --- | --- | --- | --- |
| `platform-up` | 0.225 s | 0.211 s | 0.211 s | no |
| `converge` (head node) | 47.740 s | 47.415 s | 50.050 s | no |
| `nodes-up` (the boot loop) | 28.135 s | 29.342 s | 34.509 s | slightly |
| `nodes-activate` (burn-in, gate, promotion reboot) | 95.482 s | 126.176 s | 189.203 s | **yes, linear** |
| `slurm-ready` | 12.144 s | 12.150 s | 12.178 s | no |
| **wall clock** | **183.8 s** | **215.3 s** | **286.2 s** | |

The interesting result is not how long one node takes. It is **which phases
stay flat**: `converge` does not move, which is the check that no per-node work
leaked into a per-run step. The phase that bends is the image and overlay fetch
(`overlay`: 6.80 s at one node, 7.44 s at two, 11.24–11.87 s at four), and that
is the phase the scale argument is built on.

## What this does not prove

Three gaps, disclosed on purpose. A gap that is named is a design decision; a
gap the reader finds is a credibility failure.

- **No InfiniBand hardware, and never any.** The GUID discovery and the DHCP
  option-61 client-id reservations are real code, exercised only against
  synthetic GUID data. The RDMA numbers above are Soft-RoCE over Ethernet —
  a genuine verbs data path and an unreal fabric, with no subnet manager.
  See [`docs/ib-and-dhcp-option61.md`](docs/ib-and-dhcp-option61.md) and
  [`docs/rdma-soft-roce.md`](docs/rdma-soft-roce.md).
- **No real BMC.** `sushy-emulator` gives real power on/off/cycle and real
  persistent boot-order changes — the path OpenStack Ironic uses in its own
  CI. It does **not** give vendor BIOS attributes: the pending/applied two-step,
  `@Redfish.Settings` semantics, or attribute names that change spelling
  between firmware releases. See [`docs/redfish.md`](docs/redfish.md).
- **Nothing above four nodes.** One workstation fits a handful of guests. The
  DHCP and image-pull stampede at 100 nodes is **arithmetic over a measured
  per-node cost**, not an observation, and it is labelled that way wherever it
  appears. Where it breaks — starting with an address plan that fails at node
  81, not with throughput — is in
  [`docs/scale-analysis.md`](docs/scale-analysis.md).

## How it works

Every box is a real path in this repository or in `cluster-images-wip`. If a
box has no path, it is not part of the system. The boot-path diagram and the
rest of the detail are in [`docs/architecture.md`](docs/architecture.md).

```mermaid
flowchart LR
  OP["operator<br/>make up, make demo N=n, make acceptance<br/>Makefile"]

  subgraph HEAD["head node — one workstation, WSL2 Ubuntu, systemd"]
    direction TB
    ANS["ansible/site.yml<br/>head-node convergence, push<br/>make converge"]
    NET["lab-net.service<br/>br-prov, a bridge with no uplink<br/>systemd/lab-net.service.in, scripts/net-up.sh"]
    DNS["lab-dnsmasq.service<br/>DHCP, TFTP and DNS, bound to br-prov only<br/>ansible/roles/dnsmasq/"]
    NB["NetBox — the source of truth<br/>ansible/roles/netbox/, netbox/seed.py"]
    WW["warewulfd<br/>node image and per-node overlays over HTTP<br/>ansible/roles/warewulf_server/"]
    API["cluster-node-api<br/>the only holder of a NetBox token<br/>ansible/roles/node_api/"]
    MIR["git mirror, publishes the deployed ref only<br/>ansible/roles/git_mirror/"]
    SCTL["slurmctld, configless<br/>ansible/roles/slurm_controller/<br/>ansible/roles/slurm_config/"]
    RF["sushy-emulator — Redfish power and boot order<br/>ansible/roles/sushy_emulator/, scripts/redfish.sh"]
    PROM["Prometheus — convergence and staleness alerts<br/>ansible/roles/prometheus/"]
  end

  subgraph NODE["compute node, N of them — UEFI q35 guest, no inbound SSH, no credential"]
    direction TB
    BOOT["UEFI PXE, iPXE, two-stage dracut<br/>scripts/nodes-up.sh"]
    PULL["cluster-pull.service and .timer<br/>ansible-pull -C deployed ansible/local.yml<br/>ansible/roles/warewulf_server/files/cluster-pull/"]
    ROLES["node-local roles only<br/>node_facts, network_from_netbox, munge, node_exporter,<br/>rdma_soft_roce, burnin, slurm_compute, convergence_report<br/>ansible/roles/"]
    SLURMD["slurmd --conf-server<br/>no slurm.conf on the node, ever<br/>ansible/roles/slurm_compute/"]
  end

  GHA["GitHub Actions builds the node images<br/>cluster-images-wip/.github/workflows/images.yml"]
  GHCR["ghcr.io/dchau360/cluster-images-wip<br/>public packages, one tag per commit"]
  LAN["home LAN, reached only by WSL's eth0 NAT<br/>carries no DHCP, no TFTP and no image<br/>scripts/verify-isolation.sh"]

  OP --> ANS
  ANS --> NET
  ANS --> DNS
  ANS --> NB
  ANS --> WW
  ANS --> SCTL
  ANS --> RF
  NB -->|"reservations rendered from it"| DNS
  NB -->|"slurm.conf and topology.conf rendered from it"| SCTL
  NB --- API
  GHA -->|"push on main"| GHCR
  GHCR -->|"wwctl image import docker://..., no credential"| WW
  RF -->|"power cycle, persistent boot order"| BOOT
  BOOT -->|"DHCP, TFTP"| DNS
  BOOT -->|"image and overlays over HTTP"| WW
  BOOT --> PULL
  PULL -->|"git clone, pinned ref"| MIR
  PULL --> ROLES
  ROLES -->|"GET /v1/self, POST convergence and burn-in"| API
  ROLES --> SLURMD
  SLURMD -->|"fetches its configuration over Slurm RPC"| SCTL
  PROM -->|"scrapes"| API
  NET x-- "no route, by construction" --x LAN
```

Read it as a sentence: the operator pushes to the **head node** only; the head
node serves images, addresses, facts and a pinned git ref onto an **isolated
segment**; each **node** pulls its own configuration from that segment and
reports back; and the only thing crossing in from the public internet is a
node image from a public registry, fetched with no credential.

## Start here

In the order a stranger should read them:

1. [`docs/case-study.md`](docs/case-study.md) — the whole project in first
   person: the problem, the decisions, the numbers, the bugs that taught the
   most, and what would be done differently.
2. [`docs/tradeoffs.md`](docs/tradeoffs.md) — the three decisions that shaped
   it, each with the option **not** taken and what that option is genuinely
   better at: the four-node scale analysis, the image-versus-Ansible split, and
   the pull-versus-push split.
3. [`docs/architecture.md`](docs/architecture.md) — the diagrams, the boot
   path phase by phase, where configuration comes from, where state lives.
4. [`docs/measurements.md`](docs/measurements.md) — the 1-to-N curve, every
   phase, per node, including a measurement that was wrong and how it was
   caught.
5. [`docs/scale-analysis.md`](docs/scale-analysis.md) — four named failure
   modes at 100 nodes, labelled measured or projected, and the order to fix
   them in.
6. [`docs/node-self-configuration.md`](docs/node-self-configuration.md) — the
   pull design, the four jobs a node cannot do for itself, and the drills that
   tested them.
7. [`docs/acceptance-drills.md`](docs/acceptance-drills.md) — every drill with
   its console output.

Also: [`docs/operations.md`](docs/operations.md),
[`docs/network-isolation.md`](docs/network-isolation.md),
[`docs/discovery.md`](docs/discovery.md),
[`docs/redfish.md`](docs/redfish.md),
[`docs/rdma-soft-roce.md`](docs/rdma-soft-roce.md),
[`docs/ib-and-dhcp-option61.md`](docs/ib-and-dhcp-option61.md),
[`docs/lab-host-setup.md`](docs/lab-host-setup.md).

> This repository is **public**. Every commit is world-readable forever.
> Read [Repository rules](#repository-rules) before your first commit.

## Quick start

```sh
cp lab/local.env.example lab/local.env   # fill in the host-specific values
make up                                  # bring the platform up, idempotent
make demo N=2                             # 2 nodes, power-off to Slurm-ready
make demo N=4                             # same code, 4 nodes
make acceptance                           # the whole curve, then every drill
make down                                 # stop the lab
```

`make help` lists everything. [`docs/lab-host-setup.md`](docs/lab-host-setup.md)
is what the host needs, and why. [`docs/operations.md`](docs/operations.md) is
how to check the lab, open the NetBox inventory, and add or replace a machine.

## What is here

| Working now | Where |
| --- | --- |
| Isolated provisioning bridge, no route to the home LAN | `scripts/net-up.sh` |
| dnsmasq bound to that bridge only: DHCP, TFTP, the Warewulf PXE chain | `scripts/net-up.sh` |
| UEFI/OVMF nodes, created, re-provisioned and destroyed by the harness | `scripts/nodes-up.sh` |
| Warewulf image import from GHCR, node/profile definitions, identity overlays | `ansible/roles/warewulf_server/` |
| NetBox as source of truth; dnsmasq reservations rendered from it | `ansible/roles/netbox/`, `ansible/roles/dnsmasq/` |
| Discovery boot that registers itself in NetBox and claims its IPAM address | `scripts/discover.sh`, `cluster-images-wip` |
| Redfish power and boot order via `sushy-emulator` | `ansible/roles/sushy_emulator/`, `scripts/redfish.sh` |
| Nodes that configure themselves by `ansible-pull` from a pinned ref | `ansible/local.yml`, `ansible/roles/warewulf_server/tasks/pull_overlay.yml` |
| A node API that holds the only NetBox token and answers only about the caller | `ansible/roles/node_api/` |
| Burn-in gate, Slurm registration and a job array on every node | `scripts/nodes-activate.sh`, `scripts/slurm-ready.sh` |
| Configless Slurm rendered from NetBox, including `topology.conf` | `ansible/roles/slurm_config/` |
| Soft-RoCE RDMA: a real `perftest` number over `rdma_rxe`, no IB hardware | `scripts/rdma-test.sh`, `docs/rdma-soft-roce.md` |
| Rollback, rolling update, re-provision, NIC swap and cold-start drills | `Makefile`, `docs/acceptance-drills.md` |
| Convergence reporting, staleness detection and Prometheus alert rules | `ansible/roles/convergence_report/`, `ansible/roles/prometheus/` |
| Per-phase, per-node timing, NDJSON plus CSV | `scripts/lib/timing.sh` |
| Every lab service a systemd unit enabled at boot | `systemd/` |

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
  nodes-activate.sh           burn-in, the gate, and the promotion reboot
  slurm-ready.sh              wait for every node to join, then run a job array
  promote.sh rollback.sh      the release step, and both rollbacks
  day2.sh                     drain, resume, reconfigure, rolling update, gate
  discover.sh redfish.sh      the discovery boot and the Redfish client
  drill-*.sh                  the acceptance drills
  systemd-install.sh          render and install the units
  status.sh                   units, segment, nodes, leases on one screen
  verify-isolation.sh         prove the segment cannot reach the home LAN
  verify-idempotent.sh        prove a second 'make up' changes nothing
  cold-start-check.sh         prove every unit is enabled at boot
  check-no-host-values.sh     the leak gate. also runs in CI.
  check-node-count-is-variable.sh
  lib/common.sh               config loading, change accounting, primitives
  lib/timing.sh               phase_begin / phase_end / timing_report
  lib/boot-phases.sh          live console watchers for the boot phases
systemd/
  lab.target.in               one handle for the whole lab
  lab-net.service.in          the segment, at boot
  lab-dnsmasq.service.in      DHCP, DNS and TFTP, on the segment only
ansible/
  site.yml                    head-node play, asserts the invariants
  local.yml                   the node's own play, run by ansible-pull
  group_vars/all.yml          node count and segment, as variables
  inventory/lab.yml           control host. compute nodes are generated.
  roles/                      dnsmasq, warewulf, netbox, slurm, node-local roles
  playbooks/day2/             drain, resume, rolling update, burn-in gate
netbox/
  definition.yml seed.py      the source of truth, and how it is seeded
  test_*.py                   unit tests for the renderers, API and gate
molecule/
  node_pull/                  the node play, converged in a container
docs/
  case-study.md               the project in first person
  tradeoffs.md                the three decisions, both sides of each
  architecture.md             the diagrams, and how the pieces fit
  measurements.md             the 1-to-N curve
  scale-analysis.md           where it breaks at 100 nodes
  acceptance-drills.md        every drill, with its output
  node-self-configuration.md  the pull design and the four pushed jobs
  network-isolation.md        the isolation design and how it is proven
  discovery.md                the discovery boot
  redfish.md                  what the management plane does and does not do
  rdma-soft-roce.md           the RDMA numbers, and what they are not
  ib-and-dhcp-option61.md     the InfiniBand code that has no hardware
  lab-host-setup.md           what the lab host needs, and why
  operations.md               status, NetBox inventory, add or replace a node
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

**Nodes pull; only four jobs are pushed.** A compute node has no inbound SSH
and holds no credential. It configures itself with `ansible-pull` from a pinned
`deployed` ref. The head node runs the four jobs a node cannot do for itself:
the Slurm controller and its configuration, the day-2 plays, the burn-in gate,
and promotion of the `deployed` ref. Node configuration is therefore **O(1) in
node count** — no play loops over N hosts. See
[`docs/node-self-configuration.md`](docs/node-self-configuration.md) and
[`docs/tradeoffs.md`](docs/tradeoffs.md#3-pull-versus-push).

**A node grades nothing about itself.** A `staged` node runs burn-in and posts
raw measurements; any `passed` or `verdict` key it sends is dropped. The gate on
the head node recomputes pass or fail against floors held in this repository
and sets the status. Nothing a node can reach can write its own status or name.

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

MIT — see [LICENSE](LICENSE).
