# Three tradeoffs

Three decisions shaped this lab. Each one had a real alternative with a real
advantage, and each is written here the same way: the option taken, the option
**not** taken and what it is genuinely better at, why it lost anyway, and what
would change the answer.

Every scale statement below carries one of three labels, and they are not
interchangeable:

| Label | Means |
| --- | --- |
| **Measured** | observed on the lab host, with the run id or the file that recorded it |
| **Extrapolated** | arithmetic over a measured per-node cost — a projection, never an observation |
| **Designed** | a property of the configuration, readable without running anything |

---

## 1. Four nodes, and what four nodes can prove

**Decision.** Measure the pipeline at `N=1`, `2` and `4`, instrument every
phase per node from the start, and publish the slope together with a written
analysis of where it breaks at a hundred — rather than build something bigger
and measure less of it.

### What four nodes does prove

Correctness of the pipeline, end to end, with no manual step:

| Claim | Evidence |
| --- | --- |
| Power-off guests to a Slurm cluster that takes work | `make demo N=<n>`, [`acceptance-drills.md`](acceptance-drills.md#make-demo-n4--power-off-to-a-cluster) — `sinfo` idle, a job array with one task per node, all `COMPLETED 0:0` |
| The same code at any node count | the per-phase tables at `N=1`, `2` and `4`, [`measurements.md`](measurements.md#results) — no code change between them |
| Nothing knows the node count | `scripts/check-node-count-is-variable.sh`, a CI job |
| Idempotent | head converge `ok=119 changed=0`, node pull `ok=38 changed=0`, `make verify-idempotent` fails the build otherwise |
| A degraded node never joins the cluster | the burn-in gate drill: a disk throttled to 4 MiB/s was set `failed` against a 20 MiB/s floor, [`acceptance-drills.md`](acceptance-drills.md#the-burn-in-gate-holds-a-deliberately-failed-node) |
| Rollback works, both kinds | image rollback one command; config rollback one ref move, **2.95 s measured** |

### What four nodes cannot prove

**Measured:** the per-run phases are flat in `N`. `converge` is 47.4–50.1 s at
every count and `platform-up` is about 0.21 s, which is the check that no
per-node work leaked into a per-run step.

**Measured:** the phase that bends is `overlay` — the image and runtime-overlay
fetch and apply — at **6.80 s with one node, 7.44 s with two, 11.24–11.87 s
with four**. That is `warewulfd` beginning to serialise, on a bridge, with the
image in page cache.

**Measured:** the DHCP lease is flat over this range, 5.06–6.09 s at two nodes
and 5.08–6.09 s at four. An earlier build on the same host did show a step
(`firmware` 7.8 s to 13.4 s), so the contention is real but its size depends on
the image and the host state. Four nodes does not settle it.

**Measured:** the burn-in acceptance path is linear in `N` and separate from the
boot curve — `nodes-activate` 95.5 s, 126.2 s, 189.2 s at one, two and four
nodes.

**Extrapolated, and the first wall is not performance:**

| | Value | At 100 nodes |
| --- | --- | --- |
| Node address formula | `10.42.0.(PROV_NODE_IP_OFFSET + index)`, offset 19 | node 81 lands on `10.42.0.100` |
| dnsmasq dynamic pool | `dhcp-range=10.42.0.100,10.42.0.199` | node 81's reservation is **inside the dynamic pool** |
| Segment | `10.42.0.0/24` | ~244 usable addresses, so 100 nodes plus BMCs is most of the plan |

That is **designed**, not projected: it is readable straight out of the
configuration. The pipeline does not get slow at a hundred nodes — at node 81
it starts handing a dynamic address to a node that is supposed to hold a
reservation, and the symptom is an intermittently misnamed node rather than an
exhausted address plan. One line fixes it. Nobody writes that line until they
have counted.

**Extrapolated:** 386 MiB of compressed image plus its share of 41 MiB of
overlays, times a hundred nodes, is **37.7 GiB out of one HTTP server** — about
5.5 minutes of wire time on 1 GbE at line rate, which no real server reaches
while fanning out a hundred connections. The measured `overlay` bend is the
reason to believe this is optimistic rather than pessimistic.

**Extrapolated:** the rolling image update is **211.9 s measured** for four
nodes, dominated by a 42 s per-node health wait, and it is serial by design.
At a hundred nodes that is **1.2 hours with an empty drain, ~1.8 hours** if each
node has real work to drain first. The fix is not an optimisation; it is a
policy decision about how many nodes may be out at once, and this harness has
no knob for it. That gap is named rather than hidden.

The whole analysis, with all four named failure modes and the order to fix them
in, is [`scale-analysis.md`](scale-analysis.md).

### The option not taken

**A bigger cluster: cloud instances, or containers standing in for nodes.**

Its genuine advantage is the one thing this lab cannot buy. A hundred real
DHCP clients contending for one `dnsmasq`, and a hundred real HTTP fetches
against one `warewulfd`, would turn the two weakest statements in this
project — failure modes 1 and 2 — from arithmetic into measurement. That is
exactly the evidence an interviewer should want.

**Why it lost.** The thing being demonstrated is *bare-metal provisioning*:
UEFI firmware, PXE, DHCP option handling, a two-stage `dracut` boot, per-node
overlays, Redfish power control. Containers have no firmware and do not PXE
boot, so a hundred containers would prove the scale of a system that is not
this one. Cloud instances already have an operating system by the time you can
reach them, which deletes the entire problem. The choice was between
**measuring the wrong pipeline at a hundred nodes** and **measuring the right
pipeline at four, then writing down exactly where the four-node evidence stops
being evidence**. The second is a smaller claim that happens to be true.

**What would change the answer.** Bare-metal-as-a-service with real firmware —
Equinix Metal, or a borrowed rack — for even one day. The experiment is already
designed: stage the power-ons in waves over Redfish, hold the image constant,
and watch whether `overlay` keeps the slope it showed between two nodes and
four. Until that runs, the honest sentence is *"I measured one to four, here is
where it breaks at a hundred, and here is why"*, and that is the sentence this
documentation is built to let the user say.

---

## 2. The image versus Ansible split

**Decision.** Everything identical on every node and expensive to build goes
into the GHCR image, built once in CI. Everything per-node, per-cluster or
secret is applied by Ansible on the node at boot. The line is drawn by
*where the bytes come from*, not by convenience.

| In the image (`cluster-images-wip`) | In Ansible (`ansible/local.yml`) |
| --- | --- |
| Kernel, dracut, the `wwinit` initramfs | Hostname and addresses (`network_from_netbox`) |
| Every package — `images/*/packages.txt` | The Munge key, from the overlay (`munge`) |
| Slurm 25.11, built from the pinned upstream tarball | `slurmd` unit and `--conf-server` wiring (`slurm_compute`) |
| The RDMA userspace: `rdma-core`, `libibverbs-utils`, `perftest` | Creating the `rxe` device on the node's own NIC (`rdma_soft_roce`) |
| The `slurm` service account | Burn-in and its raw numbers (`burnin`), `node_exporter`, `convergence_report` |
| `pynetbox` and the discovery payload | Fetching the node's own facts (`node_facts`) |

Two of those rows were decided by failure, not by taste, and both are worth
telling:

* **The RDMA userspace had to move into the image.** `rdma_rxe` ships with the
  kernel, but `libibverbs-utils` and `perftest` do not, and the provisioning
  segment has **no uplink** — there is no package mirror a node could reach,
  by construction. The node cannot install them for itself at any node count.
  It is in `images/compute-base/packages.txt` because the network design put
  it there.
* **The `slurm` service account was missing from the source-built image**, so
  configless `slurmd` exited immediately. The fix is deliberately in both
  places: `slurm_compute` creates `cluster_slurm_user`, and the image ships it.
  A node that boots an older image still converges.

### Why installing packages at boot fails at 100 nodes

Three reasons, and only the third is about speed:

1. **Designed:** it cannot work here at all. The segment has no route off it.
   A package transaction at boot needs a mirror on the segment, which is a new
   service to build, secure and keep in sync with the image.
2. **Designed:** it destroys reproducibility. A node provisioned on Tuesday
   and a node provisioned on Friday would hold different package sets from the
   same commit. The 1-to-N curve would be measuring the mirror's mood. This is
   the same reason `IMAGE_BASE` is a pinned tag in `lab/local.env.example`.
3. **Extrapolated:** it turns one fan-out into two. The image fetch is already
   37.7 GiB at a hundred nodes and the measured `overlay` phase already bends
   from 7.44 s to ~11.9 s between two nodes and four. Adding a hundred
   simultaneous package transactions — each with its own metadata refresh,
   dependency solve and download — puts a second contended service beside the
   first, and the dependency solve is CPU on the node while the download is I/O
   on the mirror, so the two do not even queue politely.

The split also keeps the measurement honest. `compute-slurm` and `discovery`
are **layers** on `compute-base`, so a Slurm change does not rebuild the
kernel, dracut or the `wwinit` initramfs, and the `image-build` phase reports
the cost of what actually changed. See
[`image-design.md`](https://github.com/dchau360/cluster-images-wip/blob/main/docs/image-design.md).

### The option not taken

**A thin generic image plus a fat Ansible run.** Boot a near-stock distro
image and let `ansible-pull` install Slurm, the RDMA userspace and everything
else on first boot.

Its genuine advantage is real and it is iteration speed. Changing a package
set would be a commit and a `make promote` — about three seconds of ref
move — instead of a CI image build, a GHCR push, a `wwctl image import` and a
node reboot. One image would serve every node role, so there would be no
layering, no tag matrix and no version skew between an image and a playbook.
For a lab where the point is to try things quickly, that is the better
developer experience, and it is not a small advantage.

**Why it lost.** The isolated segment makes it impossible, and the
reproducibility argument makes it undesirable even if a mirror existed. There
is also a correctness trap: Slurm's configless RPC only works across three
major releases, the controller runs 25.11 and EPEL 9 ships 22.05, so "install
`slurm-slurmd` from the distro" is not a slower path to the same place — it is
a path to a node that cannot talk to the controller at all.

**What would change the answer.** A provisioning segment with a local mirror
on it — which is what any real site has, because `dnf` on a hundred nodes is
how real sites patch — plus a content-addressed pin so a boot on Friday
installs Tuesday's bytes. With both of those, the fat-Ansible option becomes
reasonable for anything above the kernel and the initramfs. The kernel, dracut
and the `wwinit` initramfs stay in the image regardless: those are what the
node needs in order to boot far enough to run Ansible at all.

---

## 3. Pull versus push

**Decision.** Node-local convergence is **pull**: each node runs
`ansible-pull -C deployed ansible/local.yml` against a git mirror on the head
node, on boot and then on a splayed timer. Orchestration is **push**: the head
node runs the jobs a node cannot do for itself. The design and its evidence are
in [`node-self-configuration.md`](node-self-configuration.md).

### The four jobs a node cannot do for itself

Not "should not" — *cannot*, and each for a different reason:

| Job | Entry point | Why a node cannot |
| --- | --- | --- |
| The Slurm controller and its configuration | `make converge`, `make reconfigure` | `slurm.conf` describes **every** node, so it is a fleet-wide fact. A node knows only itself. |
| Day-2 plays: drain, resume, rolling update | `make drain`, `make rolling-update TAG=...` | Draining is a decision about the *cluster's* work. A node reimaging itself cannot wait for its own jobs to finish and then watch itself come back. |
| The burn-in acceptance gate | `make burnin-gate` | A node must not grade its own hardware. The node posts raw measurements; any `passed` or `verdict` key it sends is **dropped** by the API, and pass or fail is recomputed on the head node against floors held in this repository. |
| Promotion of the `deployed` ref | `make promote SHA=<commit>` | This is the release decision. A node that could move the ref it follows is a node that can configure itself into anything. |

The head node never logs in to a node to do any of it. Rebooting is Redfish;
draining is `slurmctld`; health is what the node itself reported to NetBox.
There is no inbound SSH to a compute node — `root@<node>:22` is refused, and
that is recorded as evidence, not asserted.

### Why node-local convergence is pull

**Designed, O(1) in node count:** there is no play that loops over `N` hosts,
so Ansible's `forks` limit never applies to node configuration at all.
`ansible/ansible.cfg` leaves `forks` unset, so it is the default 5; a push
design would serialise a hundred nodes into **20 batches of 5**, each batch
paying SSH setup, fact gathering and task execution. That cost is simply not
in this design. The fork limit still bounds the day-2 plays, and those run
against the head node, which is one host.

**Designed:** no credential on a node, in either direction. A node holds no
NetBox token and no SSH key; `cluster-node-api` on the head node holds the one
token and offers a node three calls, all about itself, none of which can write
a status or a name. A push design needs the mirror image of that: a key on the
head node that can become root on every node in the cluster.

**Designed:** a node that was powered off during a change is not stale
forever — it converges on its next boot, because convergence is something the
node does rather than something that was done to it once.

**Measured:** it degrades to last-known-good rather than to half-applied.
`local.yml` fetches facts first, so an unreachable head node means nothing has
been touched; an unreachable mirror means `ansible-pull` fails before the play
exists, the previous checkout and every running service are untouched, and the
run reports `failed` with `fetch deployed from mirror (exit 2)` as the failing
step. `make convergence-status` then exits non-zero. That drill was run.

### Why pull needs a pinned ref and a release step

A pull loop tracking `main` is a loop that ships every commit to every node
automatically, with the author's local test as the only gate. The blast radius
of one typo is the whole fleet, and the fleet applies it at a time nobody
chose.

So the mirror publishes **only** `deployed`, and a commit reaches `deployed`
only through `make promote SHA=<commit>`, which refuses any commit whose CI is
not green — including the `pull check-mode` job, which runs `local.yml --check`
inside the node image, under systemd, with the node's own `ansible-core`,
exactly as `ansible-pull` would. GitHub enforces the same required check on the
branch itself, so the gate is not a convention inside a script.

**Measured, and this is the drill that justifies the whole mechanism:** a
variable typo in a role passes both `yamllint` and `ansible-lint`. `pull
check-mode` fails it, `make promote` prints `REFUSED`, and a direct push to
`deployed` is rejected by branch protection. Three gates, and the two cheap
ones did not catch it.

**Blast radius and rollback.** A bad commit on `main` reaches zero nodes. A
bad commit on `deployed` reaches all `N`, on their next pull. That asymmetry is
why promotion is a gate and why rollback is one ref move:
`make promote SHA=<previous>` — **2.95 s measured**, and `make promote` prints
the rollback command when it promotes, so the person who needs it is not
composing it under pressure. Who notices: `make convergence-status` exits
non-zero, and Prometheus raises `ClusterNodeConvergenceStale` after
`CONVERGENCE_STALE_SECONDS`.

**Designed:** `cluster-pull.timer` repeats `PULL_INTERVAL` after the previous
run ends, plus a random `RandomizedDelaySec=PULL_SPLAY`, so `N` nodes never hit
the mirror in the same second. Without the splay, pull would recreate the
stampede it was chosen to avoid.

### The option not taken

**Push: `ansible-playbook -i inventory all` from the head node, over SSH.**

Its genuine advantages are substantial, and three of them are things this
design actually gave up:

1. **Synchronous feedback.** You know when the change finished and you know
   whether it worked, from an exit code in your own terminal. Under pull you
   know only what each node later reported, which is why
   `cluster-node-api`, the convergence fields, `make convergence-status` and
   two Prometheus rules all had to be built. That is a real pile of
   observability machinery that push would not have needed.
2. **Ordering.** "These nodes first, then those" is a `serial:` keyword. Under
   pull, ordering is not expressible at all — each node decides when it
   converges — which is exactly why the rolling update is a *push* play.
3. **No node-side agent.** Nothing to install in the image, no timer, no
   wrapper, no mirror to keep running. A node is just a machine with an SSH
   port.

**Why it lost.** The fork limit makes it `O(N/5)` where pull is `O(1)`; the
credential it requires is the single highest-value secret in the design; and a
node that is down during a push stays stale with nothing watching. For a
*provisioning* system in particular, push has a bootstrap problem that pull
does not: a freshly PXE-booted node has to be known, reachable and trusted
*before* it can be configured, whereas a pull node configures itself on the
way up and announces itself afterwards.

**What would change the answer.** A cluster small enough that `O(N/5)` is
`O(1)` in practice — roughly 20 nodes or fewer — run by one operator who wants
to watch changes land, would be better served by push, and the node-local roles
would still work unchanged: none of them uses `delegate_to`, `local_action`,
`run_once` or another host's `hostvars`, and
`scripts/check-node-roles-are-local.sh` fails CI on any of them. That
constraint is what makes the choice reversible, and it was enforced from the
start for exactly that reason. A site policy forbidding outbound git from a
compute node would also force push — and then the mirror becomes a push
target, not a pull source.

---

## Read next

* [`case-study.md`](case-study.md) — the whole project in first person: the
  problem, the decisions, the numbers, and what would change next time.
* [`measurements.md`](measurements.md) — the 1-to-N curve, every phase, per
  node.
* [`scale-analysis.md`](scale-analysis.md) — the four named failure modes at
  100 nodes, and the order to fix them in.
* [`node-self-configuration.md`](node-self-configuration.md) — the pull design
  and the drills that tested it.
