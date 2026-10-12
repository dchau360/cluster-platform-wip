# Where this breaks at 100 nodes

Four nodes proves the pipeline is **correct**. It cannot prove it **scales**,
because the failures that matter at 100 nodes do not appear at four. This
document is the measurement that lets the honest answer be *"I measured 1 to
4, here is where it breaks at 100, and here is why"* instead of *"it should
scale"*.

The curve itself — every phase, per node, at each count — is in
[`measurements.md`](measurements.md). This document is the analysis: which
phases are flat, which bend, where the first wall is, and what would have to
change.

**The lab cannot run 100 nodes.** One Windows host with 10 cores and 15 GiB
to WSL fits a handful of 2-vCPU guests, not a hundred. Everything below is
therefore a projection from the measured 1-to-4 slope plus the serialisation
points that can be read directly out of the configuration. Where a number is
projected it says so, and where it comes from a measurement it says that too.

<!-- MEASURED-SCALE -->

## The first wall is not performance. It is the address plan.

Before any throughput argument, the configuration stops working:

| | Value | Consequence at 100 nodes |
| --- | --- | --- |
| Node address formula | `10.42.0.(PROV_NODE_IP_OFFSET + index)`, offset 19 | node 81 is `10.42.0.100` |
| dnsmasq dynamic pool | `dhcp-range=10.42.0.100,10.42.0.199` | the reservation for node 81 is **inside the dynamic pool** |
| Segment | `10.42.0.0/24` | about 244 usable addresses, so ~100 nodes plus BMCs is already most of it |

So the pipeline does not slow down at 100 nodes — at node 81 it starts
handing a dynamically-allocated address to a node that is supposed to hold a
reservation, and the failure looks like an intermittently misnamed node
rather than like an exhausted plan. This is a one-line fix (`/22`, and a
dynamic pool that cannot overlap the reservations), and it is a fix nobody
makes until they have counted. Counting is the point of this document.

## What is flat in N, and why that is the interesting part

The per-run phases — `preflight`, `systemd-install`, `net`, `services`,
`platform-up`, `converge` — do not move with N. That is the check that no
per-node work has leaked into a per-run step, and it holds.

Two architectural choices are why more of the system is flat than one would
expect:

- **Nodes pull; the platform does not push.** Configuration is
  `ansible-pull` on each node from a pinned `deployed` ref. There is no
  play that loops over N hosts, so Ansible's `forks` limit — unset in
  `ansible/ansible.cfg`, therefore the default 5 — never applies to node
  configuration at all. A push design would serialise 100 nodes into 20
  batches of 5, each batch paying SSH setup, fact gathering and task
  execution. That cost is simply not in this design. The fork limit still
  bounds the day-2 plays, and those run against the head node, which is one
  host.
- **Slurm is configless.** `slurmctld` runs with `enable_configless` and each
  `slurmd` fetches `slurm.conf`, `cgroup.conf`, `gres.conf` and
  `topology.conf` over Slurm's own RPC at start. `make reconfigure` writes
  one host, not N. Distributing configuration is O(1) in node count.

## Where it bends: four named failure modes

### 1. The image pull saturates the boot server

Measured, on this host:

| | |
| --- | --- |
| Image served to each node | `compute-slurm.img.gz`, **386 MiB** (832 MiB uncompressed) |
| Server | one `warewulfd`, one HTTP listener, reading from one local disk |
| Runtime overlays | 41 MiB total for the fleet, per-node slices of it |

At 100 nodes booting together that is **38.6 GiB** out of one HTTP server.
On a 1 GbE uplink the wire time alone is about **5.5 minutes** at line rate,
before disk reads, gzip and TCP fairness; on 10 GbE, about 33 seconds at line
rate, which real servers do not reach while also fanning out 100 connections.
In this lab the fetch is a bridge on the same host and the image is in page
cache, so the measured per-node fetch cost is nearly flat — which is exactly
why the lab cannot be trusted on this point and the arithmetic has to carry
it.

What would change: Warewulf's own options first — serve the image over
multicast or BitTorrent-style distribution rather than N unicast HTTP
fetches, or put a read-only replica per rack. Failing that, a caching proxy
per leaf switch. The thing to measure before choosing is the *second* boot:
once the image is in each node's page cache none of this matters, so the cost
is paid at first boot and after every image promotion, which makes the
rolling update (below) the schedule that actually hurts.

### 2. Simultaneous DHCP times out and retries

Measured, on this host: one `dnsmasq` answers every request, and the
contention is already visible at four nodes. The first node served completes
`firmware` in 7.8 s at N=2; at N=4 every node takes 13.5–14.1 s. The shape is
a **step, not a slope** — each node's negotiation serialises behind the
others, and within one run the nodes then finish together.

The projection is where this gets dangerous. PXE firmware does not wait
politely: it retries with a backoff and then gives up. A hundred nodes
powered on together produce a hundred `DHCPDISCOVER` bursts at one
single-threaded daemon that is also answering TFTP for `snponly.efi`. The
failure is not a slow boot; it is a fraction of nodes falling out of PXE to
the next boot device and sitting at an empty disk — intermittently, and
differently each time, which is the worst possible failure to debug.

What would change: more DHCP servers, or none. Either a DHCP relay per rack
with multiple backends, or a scheduled power-on (Redfish is already here, so
powering 100 nodes on in waves of ten is a loop, not a new subsystem), or
`dnsmasq` replaced with something that answers DHCP from more than one
thread. Also: `PROV_DHCP_LEASE` is 10 minutes, which is fine for a lab and
far too short for a hundred nodes re-leasing in lockstep.

### 3. Per-node API calls add up — and the measured numbers say *minutes*, not hours

This is the one where measuring changed the answer.

| | Measured |
| --- | --- |
| NetBox API round trip on this host | **85 ms** (20 sequential GETs, 1.706 s) |
| Calls per node in `seed.py` | ~17, all sequential (device, interface, MAC, three addresses, fabric port and cable) |
| Projected seeding time at 100 nodes | ~17 × 0.085 s × 100 ≈ **145 s** per converge |

Two and a half minutes is annoying, not fatal, and it is trivially fixable
with NetBox's bulk endpoints or with concurrency. The honest finding is that
the per-node NetBox cost is **not** where the hours are.

The hours are here:

| | Measured at N=2 | Projected at 100 |
| --- | --- | --- |
| Rolling image update | 190 s for 2 nodes, of which 62 s was one node's drain and 42 s its health wait | **~2.6 hours** |

The rolling update is serial **by design** — drain one node, wait for its
jobs, reimage, reboot, wait for healthy, resume, next — and the dominant term
is the drain, which waits for real work to finish. At 100 nodes that is a
working day of rollout, and the design question is not how to speed up a step
but how many nodes may be out at once. The answer is a policy decision (what
fraction of the cluster can be down), not an optimisation, and this harness
has no knob for it today. That is the gap worth naming.

### 4. The burn-in gate is one serial pass

Every freshly-provisioned node runs its own burn-in — `stress-ng` and `fio`,
in parallel across nodes, so that part is flat. The gate then reads every
staged node, judges it and PATCHes a status: one pass, a handful of API calls
per node, so about the same order as seeding. What is not flat is the
power-cycle after promotion: `nodes-activate` cycles the promoted nodes one
at a time and watches each console to a login prompt. At four nodes that is
seconds each; at 100 it is a second full boot of the whole fleet, which lands
straight back on failure modes 1 and 2.

What would change: cycle in waves, and have the gate promote in batches so
the reboots are spread rather than simultaneous.

## Stated plainly: what is untested above four nodes

Two gaps. Both are gaps in the **evidence**, not in the reasoning, and
neither can be closed on this hardware.

1. **The DHCP and image-pull stampede.** Everything in failure modes 1 and 2
   above N=4 is arithmetic over a measured per-node cost, not an observation.
   A hundred nodes contending for one `dnsmasq` and one `warewulfd` has never
   been run here. The step from N=2 to N=4 is real evidence that contention
   exists and is serialising; it is not evidence of what that curve does at
   100, and a step function that stays flat from 4 to 100 is as consistent
   with the data as one that collapses.
2. **Real vendor BIOS attributes.** The management plane is
   `sushy-emulator` in front of libvirt. Power on, power off, cycle and boot
   order are exercised against it and they work. What has never been touched
   is a real BMC: vendor-specific `Bios` attribute names, the
   pending/applied two-step with its reboot, firmware versions that change
   attribute spelling between releases, `@Redfish.Settings` semantics, and
   per-vendor non-compliance. Setting a BIOS attribute on a Dell iDRAC and on
   an HPE iLO are not the same operation, and neither resembles the emulator.
   See [`redfish.md`](redfish.md), which says the same thing about the same
   boundary.

A third, smaller one, for completeness: there is no InfiniBand hardware and
no subnet manager, so the RDMA work is Soft-RoCE over Ethernet. That is a
real verbs data path and an unreal fabric, and
[`rdma-soft-roce.md`](rdma-soft-roce.md) is explicit about which is which.

## What to do first, in order

If this had to go to 100 nodes, the order follows the measurements rather
than intuition:

1. **Fix the address plan.** It breaks at node 81 and costs one line.
2. **Stage the power-ons.** Redfish is already in place; waves of ten make
   failure modes 1, 2 and 4 all smaller at once, with no new component.
3. **Measure, don't assume, the image fan-out.** Build the 100-node boot as a
   test against one `warewulfd` with throttled clients before choosing
   multicast or replicas.
4. **Decide the rolling-update concurrency policy.** This is the 2.6-hour
   number, and it is a policy question, not an engineering one.
5. **Bulk or parallelise the NetBox seeding.** Last, because 145 s is the
   smallest number on this page — and it is on the list only because it was
   measured rather than guessed.
