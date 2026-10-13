# Case study: from powered-off hardware to a cluster that takes work

This is the project in my own words — the problem I set myself, the decisions
I made, the numbers I measured, and what I would do differently. Every claim
here links to the code, the measurement or the drill that proves it. If I
could not link it, I cut it.

## The problem

I wanted to be able to answer one question properly: *what actually happens
between a powered-off server and a compute node that runs someone's job?*

Not the cloud version of that question, where an operating system is already
running by the time you can reach the machine. The bare-metal version: UEFI
firmware, a DHCP offer, a TFTP fetch, an iPXE script, a kernel and an
initramfs, a root filesystem that arrives over the network, an identity that
has to come from somewhere other than the image, and a scheduler that has to
be told the node exists.

I had one Windows workstation. So the constraint I accepted up front was that
I would build the whole pipeline at a handful of nodes, instrument every phase
of it from the beginning, and then be precise about which of my statements are
measurements and which are projections. I would rather defend a small true
claim than a large vague one.

## The result

`make demo N=<n>` goes from powered-off guests to a Slurm cluster that has run
a job on every node, with no manual step. At four nodes that is **286 seconds**
end to end, measured, run `20261013T000455Z-686422`
([`measurements.md`](measurements.md#results)).

The same command at one and two nodes reaches the same end state with no code
change: 183.8 s and 215.3 s. Nothing in either repository knows a node count —
`scripts/check-node-count-is-variable.sh` is a CI job that fails on a literal
`NODE_COUNT` assignment, a literal loop bound or a hardcoded node-name list.

Inside those 286 seconds: an isolated bridge comes up, dnsmasq binds to it and
to nothing else, NetBox is seeded, Warewulf imports a node image from a public
GHCR package with no credential anywhere, four UEFI guests PXE-boot, each one
configures itself with `ansible-pull` from a pinned git ref, each runs its own
burn-in and posts the raw measurements, the head node grades them and promotes
the ones that pass, the promoted nodes power-cycle and register with
`slurmctld`, and a job array runs one task on every node. The console output
of all of it is in
[`acceptance-drills.md`](acceptance-drills.md#measured-results).

## The decisions I would defend in an interview

### I built the measurement before I built the thing being measured

`phase_begin` / `phase_end` in `scripts/lib/timing.sh` existed before most of
the phases did. The reason is boring and it paid for itself: instrumentation
retrofitted onto a working system measures whatever is convenient to measure,
and the 1-to-N curve was the deliverable.

It paid for itself in a way I did not expect. The `dhcp-lease` phase watches
for a node's MAC in the dnsmasq lease file — and a node that is already running
holds a lease already, so the phase happily reported **0.015 s** and a status
of `ok`. That is not a fast DHCP lease; that is a measurement of nothing,
reported as a success. The fix was to drop the old lease before a boot and to
record an already-running node as `skip` with `"seconds": null` rather than
zero, because zero is a measurement and this is the absence of one. I kept the
wrong numbers in the document next to the right ones
([`measurements.md`](measurements.md#why-dhcp-lease-in-particular)):

| `N=2` | first lease | last lease |
| --- | --- | --- |
| clean lease file | 5.104 s | 6.115 s |
| stale lease left, **before** the fix | 0.015 s | 0.031 s |
| stale lease left, **after** the fix | 5.109 s | 6.121 s |

The lesson I actually took from it: ask of every new measurement *"what would
fool this?"* at the same time as writing it, not later.

### The provisioning segment has no uplink, and that is proven rather than asserted

`br-prov` is a Linux bridge with no port except node taps. There is no path to
the home LAN by construction, and three further measures make that enforced
rather than habitual: IP forwarding off on the interface, an nftables table of
our own that drops anything forwarded into or out of the bridge, and dnsmasq
bound to the bridge address with `bind-interfaces`.
`make verify-isolation` proves it from inside the segment, using a network
namespace configured the way a node would be
([`network-isolation.md`](network-isolation.md)).

I care about this one because a lab DHCP server that leaks onto a home or
office LAN is the classic way a provisioning project becomes everyone's
problem. Making it structurally impossible was cheaper than remembering to be
careful.

### Nodes pull, and only four jobs are pushed

A compute node has no inbound SSH and holds no credential. It configures
itself with `ansible-pull` from a pinned `deployed` ref on a mirror the head
node serves. The head node runs exactly the four jobs a node cannot do for
itself: the Slurm controller and its configuration, the day-2 plays, the
burn-in gate, and promotion of the `deployed` ref.

That makes node configuration **O(1) in node count** — there is no play that
loops over N hosts, so Ansible's default `forks` of 5 never applies to it at
all. A push design would serialise a hundred nodes into 20 batches of five,
each batch paying SSH setup and fact gathering. I did give something up for
that, and I would rather name it than pretend otherwise: push gives you a
synchronous exit code, and I had to build `cluster-node-api`, seven convergence
fields on each NetBox device, `make convergence-status` and two Prometheus
rules to replace it. The full argument, including what push is genuinely better
at, is in [`tradeoffs.md`](tradeoffs.md#3-pull-versus-push).

### A node grades nothing about itself

A new device is created `staged`. A `staged` node runs burn-in — `stress-ng`
across every CPU with verification, `stress-ng` walking and verifying a share
of RAM, and a `fio` write-then-verify of the raw scratch disk — and posts the
**raw measurements**. Any `passed` or `verdict` key a node sends is dropped by
the API. `make burnin-gate` on the head node recomputes pass or fail against
floors held in this repository, then sets the device `active` or `failed`.
`slurmd` does not run on a `staged` node.

I tested it by breaking a node on purpose: I throttled one node's disk from the
hypervisor to 4 MiB/s against a 20 MiB/s floor. The gate set it `failed` with
`disk write_mib_per_second 4.0 < 20.0` and it never became a Slurm node.
Removing the throttle, re-staging and re-running gave 1299.5 MiB/s and the gate
set it `active`
([`acceptance-drills.md`](acceptance-drills.md#the-burn-in-gate-holds-a-deliberately-failed-node)).

### Everything has a rollback, and I timed the rollbacks

Two independent things can go wrong, so there are two rollbacks:

* **A bad image.** `make rollback TAG=sha-<previous>` re-imports the previous
  tag, rebuilds the overlays, reboots the node, and reads the tag back off the
  node's own serial console. The tag is pinned rather than moving, because
  `latest` names whatever was pushed most recently, which is exactly what a
  rollback must not do.
* **A bad configuration commit.** `make promote SHA=<previous>` — one ref move,
  **2.95 s measured**. `make promote` prints the rollback command when it
  promotes, so nobody has to compose it under pressure.

And the rollout itself rolls back under failure: I pointed a rolling update at
an image with no `slurmd` in it. The first node's pull reported `failed`, the
harness put it back on the image it had, verified it, resumed it, and **stopped
the rollout**. The second node was never touched, and 5 of 5 jobs completed
while this happened ([`node-self-configuration.md`](node-self-configuration.md#evidence)).

### Three gates, and the cheap two were not enough

A variable typo in a role passes `yamllint` and passes `ansible-lint`. What
caught it is a CI job that runs `local.yml --check` **inside the node image,
under systemd, with the node's own `ansible-core`** — exactly as `ansible-pull`
would. `make promote` refuses any commit whose CI is not green, and GitHub
enforces the same required check on the `deployed` branch, so a direct push is
rejected too. I would not have predicted which of those three gates would be
the one that mattered, which is the argument for having all three.

## The numbers

All measured on the lab host on 2026-10-13 at platform commit `5ab1a81`, node
image `sha-baa648ba99c8`.

| | N=1 | N=2 | N=4 |
| --- | --- | --- | --- |
| `platform-up` | 0.225 s | 0.211 s | 0.211 s |
| `converge` (head node) | 47.740 s | 47.415 s | 50.050 s |
| `nodes-up` (boot loop) | 28.135 s | 29.342 s | 34.509 s |
| `nodes-activate` (burn-in + gate + promotion reboot) | 95.482 s | 126.176 s | 189.203 s |
| `slurm-ready` | 12.144 s | 12.150 s | 12.178 s |
| **wall clock** | **183.8 s** | **215.3 s** | **286.2 s** |

What I read out of that, and what I would say out loud:

* **The per-run phases are flat, and that is the finding.** `converge` is
  47.4–50.1 s at every count and `platform-up` is about 0.21 s. Flat means no
  per-node work leaked into a per-run step. If it had drifted, the whole O(1)
  claim about pull and about configless Slurm would be a story rather than a
  property.
* **The phase that bends is the image fetch.** `overlay` is **6.80 s at one
  node, 7.44 s at two, 11.24–11.87 s at four**. That is one `warewulfd`
  starting to serialise — on a local bridge, with the image in page cache,
  which is the friendliest possible conditions. So my scale argument is built
  on this phase and not on a guess.
* **DHCP is flat over this range**, 5.06–6.09 s at two nodes and 5.08–6.09 s at
  four. An earlier build on the same host *did* show a step. I say both,
  because reporting only the flat run would be hiding the variance and
  reporting only the step would be inventing contention the current build does
  not show.
* **The linear cost is the acceptance path, not the boot.** `nodes-activate`
  grows 95.5 → 126.2 → 189.2 s, dominated by each node's own 61–67 s burn-in
  and its 28–30 s promotion power-cycle. Burn-in runs in parallel across nodes;
  the power-cycle does not. That is the term to plan for separately.

And one number from outside the demo, because an RDMA claim with no number is
not a claim: `ib_write_bw` averaged **396.21 MB/s** and `ib_send_bw`
**480.11 MB/s** over `rdma_rxe`, with `iperf3` over the same link at
**64.3 Gbit/s** for the only fair comparison. That is a genuine verbs data
path and an unreal fabric — Soft-RoCE over Ethernet, no InfiniBand hardware
and no subnet manager ([`rdma-soft-roce.md`](rdma-soft-roce.md)).

## The bugs that taught me the most

I keep these because a project with no recorded failures is a project whose
author was not watching.

* **A handler that never ran.** The controller's `munged` predated the cluster
  Munge key, so `slurmctld` rejected every node with an authentication error
  that pointed nowhere useful. The role now restarts a `munged` older than its
  own key — judged by wall clock, because WSL's monotonic clock drifts across
  the host's sleep.
* **Docker ate the cluster network.** `br_netfilter`, loaded by Docker, dropped
  node-to-node frames on my bridge. The symptom was perfect: `srun` from the
  head node worked and batch steps between nodes failed. `net-up.sh` now
  explicitly accepts traffic within the segment.
* **Two separate timezone bugs, both in reporting.** `now(utc=true).timestamp()`
  skewed phase starts by the zone offset, and the node API exported convergence
  times an hour old because of DST handling in `mktime`. The second one made
  both Prometheus alerts fire on a completely healthy fleet, which is the
  failure mode that teaches people to ignore alerts. I would now treat any
  local-time conversion in a monitoring path as a defect by default.
* **A green commit with a red check.** Every push to `deployed` started a CI
  run that the next promotion cancelled, leaving a cancelled check on a commit
  whose CI had passed — and `make promote` reads CI status, so the gate started
  refusing good commits. CI now skips `deployed`, and `promote.sh` judges the
  latest run per check.
* **`Failed to mount /sysroot`.** The upstream distro image has no kernel and
  no Warewulf `wwinit` dracut module, and the Ubuntu `ipxe` package has no
  `imgextract` command because that is a Warewulf patch. Two days of this
  failure taught me the two-stage `dracut` boot method properly. The image
  build now asserts the module is present with `lsinitrd ... | grep wwinit`,
  so the next person gets a build failure instead of a boot failure.

## What I would do differently

1. **I would have designed the address plan for the cluster I was arguing
   about, not the one I was running.** The node address formula is
   `10.42.0.(offset + index)` with offset 19, and the dnsmasq dynamic pool is
   `10.42.0.100` upward — so **node 81 lands inside the dynamic pool** and gets
   a dynamic address where it should hold a reservation. The symptom would be
   an intermittently misnamed node, which is a horrible thing to debug. A `/22`
   and a non-overlapping pool would have cost one line on day one. I only found
   it by counting, which is the entire argument for
   [`scale-analysis.md`](scale-analysis.md).
2. **I would put the concurrency policy in the rolling update from the start.**
   It is serial by design — drain, reimage, wait for healthy, resume, next —
   and 211.9 s for four nodes projects to **1.2 to 1.8 hours for a hundred**.
   The right answer is not a faster step, it is a policy about what fraction of
   the cluster may be out at once. There is no knob for that today, and adding
   one after the fact means revisiting every drill.
3. **I would bulk the NetBox seeding.** ~17 sequential API calls per node at a
   measured 85 ms round trip is ~145 s per converge at a hundred nodes. It is
   the smallest number in my scale analysis and the easiest to fix, and it is
   on the list only because I measured it instead of guessing — I had assumed
   it would be the dominant cost, and it is not.
4. **I would measure the second boot as carefully as the first.** Every scale
   argument I make about the image fetch concerns a cold fetch, but once an
   image is in a node's page cache the cost disappears — which means the real
   pain is concentrated at first boot and after every image promotion, and the
   schedule that hurts is the rolling update. I have the instrumentation for
   that and never pointed it at the question.
5. **I would stop treating "it is a lab" as a reason to skip the policy
   question.** Several of the gaps I am most comfortable disclosing — the
   update concurrency knob, the per-model burn-in floors, the 10-minute DHCP
   lease — are places where I built the mechanism and left the policy
   unspecified. A reviewer reads an unspecified policy as an unconsidered one.

## What this does not prove

Three gaps, disclosed on purpose. A gap I name is a design decision; a gap a
reader finds is a credibility failure.

* **No InfiniBand hardware, and never any.** The GUID discovery and the DHCP
  option-61 client-id reservations are real code exercised only against
  synthetic GUID data. The RDMA numbers above are Soft-RoCE over Ethernet.
  There is no subnet manager in this project.
  ([`ib-and-dhcp-option61.md`](ib-and-dhcp-option61.md),
  [`rdma-soft-roce.md`](rdma-soft-roce.md))
* **No real BMC.** `sushy-emulator` gives real power on, off and cycle, and
  real persistent boot-order changes — the same path OpenStack Ironic uses in
  its own CI. What it does not give is vendor BIOS attributes: the
  pending/applied two-step and its reboot, `@Redfish.Settings` semantics,
  attribute names that change spelling between firmware releases, and the fact
  that setting a BIOS attribute on a Dell iDRAC and on an HPE iLO are not the
  same operation. ([`redfish.md`](redfish.md))
* **Nothing above four nodes.** One workstation fits a handful of guests. The
  DHCP and image-pull stampede at a hundred nodes is **arithmetic over a
  measured per-node cost**, not an observation, and I label it that way
  everywhere it appears. ([`scale-analysis.md`](scale-analysis.md))

## Read next

* [`tradeoffs.md`](tradeoffs.md) — the three decisions, each with the option I
  did not take and what it is genuinely better at.
* [`architecture.md`](architecture.md) — the diagram, with every box mapped to
  a path in the repository.
* [`measurements.md`](measurements.md) — every phase, per node, at each count.
* [`acceptance-drills.md`](acceptance-drills.md) — every drill, with its
  console output.
