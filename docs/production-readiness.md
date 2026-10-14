# Production readiness: every gap between this lab and production

The lab proves a pipeline: powered-off machines to a Slurm cluster that takes
work, at any node count, measured. It is not a production cluster, and the
useful answer to *"would it survive production?"* is not "yes" or "no" — it is
**this exact list**. Every item below is a gap I know about, why it matters,
how I would close it, roughly what it costs, and whether it is done.

Three of these were on the original list from [the SRE-3 answer](#the-three-that-are-done)
and are **built** now, with the merged pull request and the drill that proves
it. Everything else is marked **designed** (the mechanism is understood and
partly present) or **not started** (it does not exist yet). Nothing here is
called built that is not.

The status vocabulary is the same one [`tradeoffs.md`](tradeoffs.md) uses, and
it is not decoration:

| Status | Means |
| --- | --- |
| **Built** | merged to `main`, with the pull request and the drill linked below |
| **Designed** | the mechanism exists in the repo or is specified here, but the production version is not done |
| **Not started** | it does not exist today, and this document is the design brief for it |

Effort is rough engineering time for one person who already knows this
codebase, not a schedule.

---

## The scoreboard

| # | Area | Item | Status | Effort |
| --- | --- | --- | --- | --- |
| 1.1 | Trust and secrets | Node identity from attestation, not an overlay | Not started | 15–25 d |
| 1.2 | Trust and secrets | Least-privilege NetBox token over TLS | Not started | 3–5 d |
| 1.3 | Trust and secrets | Munge and SSH host keys in Vault, with rotation | Not started | 5–8 d |
| 1.4 | Trust and secrets | TLS on the management plane | Not started | 5–8 d |
| 2.1 | No single head node | `slurmctld` backup controller | Not started | 5–8 d |
| 2.2 | No single head node | `slurmdbd` and MariaDB, rendered by Ansible | **Built** | — |
| 2.3 | No single head node | NetBox on managed Postgres with a tested restore | Not started | 5–8 d |
| 2.4 | No single head node | Replicated Warewulf and git mirror | Not started | 10–15 d |
| 3.1 | Scale walls | Address plan that does not collide with the pool | **Built** | — |
| 3.2 | Scale walls | Power-on in waves of about ten | Designed | 2–3 d |
| 3.3 | Scale walls | Image fan-out load test | Not started | 5–8 d |
| 3.4 | Scale walls | Rolling-update concurrency policy | Not started | 5–8 d |
| 3.5 | Scale walls | Bulk NetBox seeding | Not started | 2–3 d |
| 4.1 | Real hardware | Vendor BMC BIOS attributes | Not started | 5–10 d |
| 4.2 | Real hardware | VLANs | Not started | 5–8 d |
| 4.3 | Real hardware | Switch config from NetBox cabling | Designed | 10–15 d |
| 4.4 | Real hardware | LLDP validation | Not started | 3–5 d |
| 4.5 | Real hardware | InfiniBand subnet manager | Not started | 5–8 d |
| 5.1 | Operations | Alerting that reaches a receiver | **Built** | — |
| 5.2 | Operations | Central logs | Not started | 3–5 d |
| 5.3 | Operations | Change control with canaries | Built (control) / Not started (canaries) | 5–8 d |
| 5.4 | Operations | On-call | Not started | 2–3 d |
| 5.5 | Operations | LDAP/SSSD identity | Not started | 5–8 d |
| 5.6 | Operations | Shared storage | Not started | 10–15 d |
| 5.7 | Operations | Fair-share | Designed | 2–3 d |

The order to actually do these in is at the end:
[**If this had to ship, the order**](#if-this-had-to-ship-the-order).

---

## 1. Trust and secrets

The lab's trust model is honest about its boundary: a compute node holds no
credential, and the one thing that does (the node API) answers only about the
caller. That is good. What is missing is everything *behind* that boundary —
proving which physical machine a node is, and getting the few remaining
secrets out of flat files and off plain HTTP.

### 1.1 Node identity from attestation, not an overlay

**Gap.** A node's identity is the Warewulf runtime overlay it was assigned:
hostname, addresses, the cluster Munge key and the SSH host keys arrive
because the provisioning server decided that MAC is that node. There is no
TPM or BMC-rooted proof. If a machine reimages with a spoofed MAC, or a node's
overlay is swapped, nothing in the boot chain notices.

**Why it matters.** In a shared datacentre, "the DHCP reservation says so" is
the entire authentication story for a machine that will join a scheduler and
run other people's jobs. Production fleets root this in hardware: a TPM with
an EK, measured boot, or a BMC-scoped identity.

**Fix.** Add a `swtpm`/fTPM device to each guest (the lab host already installs
`swtpm`, per [`lab-host-setup.md`](lab-host-setup.md)), have the node enrol its
TPM EK on first boot, and have the node API accept only an enrolment signed by
that EK. Move the cluster secrets that the node receives behind that identity.
Vault (1.3) is the store; attestation is the gate. On real hardware, the same
flow reads the EK from the vendor TPM or derives it from a BMC-signed
certificate.

**Effort.** 15–25 days. It is the largest item on the page and the only one
that changes the branch logic in `pull_overlay.yml`.

**Status.** Not started. The lab host ships `swtpm`, but no VM uses it and no
code reads an EK.

### 1.2 Least-privilege NetBox token over TLS

**Gap.** The discovery overlay carries the **superuser** NetBox token
(`ansible/roles/warewulf_server/tasks/main.yml` reads `SUPERUSER_API_TOKEN`
from the NetBox environment file and renders it into the overlay), and NetBox
is served over plain HTTP on the provisioning segment. A discovery-booting
machine therefore holds a token that can rewrite all of NetBox, and it travels
unencrypted.

The steady-state node does not have this problem — `cluster-node-api` holds the
only token and exposes three self-scoped calls — but the one-shot discovery
boot does.

**Why it matters.** A superuser token in a world-readable overlay is a full
inventory compromise from any node on the segment, and a token in cleartext is
a token captured by anything that can see the segment. Both are exactly the
kind of finding an external reviewer opens with.

**Fix.** Create a scoped NetBox token that can do only what discovery needs
(create a device and claim an IP from the discovery pool) and render that
token instead of the superuser one. Put a TLS listener in front of NetBox (a
reverse proxy with a lab CA, or terminate at the NetBox container) and pin the
CA in the overlay. Long term the discovery boot should present its TPM EK
(1.1) and receive a short-lived token, which removes the long-lived secret
from the overlay entirely.

**Effort.** 3–5 days.

**Status.** Not started.

### 1.3 Munge and SSH host keys in Vault, with rotation

**Gap.** The cluster Munge key is generated once on the head node
(`dd if=/dev/urandom` in `ansible/roles/warewulf_server/tasks/main.yml`) and
distributed through a per-node overlay. SSH host keys are generated once per
type and rendered the same way. There is no Vault anywhere in this repository,
no key version, and no rotation path: re-keying Munge means regenerating the
cluster secret and getting it onto every node; re-keying SSH host keys means
the same.

**Why it matters.** A cluster Munge key is a shared secret for the whole
scheduler. It should live in a secret manager with an owner, an audit trail
and a rotation procedure, not in a file on the provisioning server. The same
is true of host keys, and an unrotatable host key is a host key that is
eventually a known one.

**Fix.** Stand up Vault (or the site's existing secret store) on the head node,
move the Munge key and the SSH host-key set into it, and have the overlay
delivery pull from Vault rather than from local files. Add a rotation runbook
and a second key so rotation is an overlap, not a flag day: distribute the new
Munge key, let `munged` restart before anything authenticates with it (the
`munge` role already does key-before-auth ordering), then retire the old one.
The `munge` role and the key-change handler already give the right shape; the
missing part is the store and the rotation.

**Effort.** 5–8 days.

**Status.** Not started. The repository's secret gates already allow a
`vault-pass`/`*.vault` workflow (`scripts/check-no-tracked-secrets.sh`), so
the policy exists before the tool.

### 1.4 TLS on the management plane

**Gap.** NetBox, the lab's other HTTP services and the Redfish endpoint
(`sushy-emulator`, whose config says in as many words "no TLS") all speak
plain HTTP on the provisioning segment. BMCs in the real world are HTTP or
self-signed HTTPS, and the tools that talk to them do not verify by default.

**Why it matters.** The management plane is where credentials go. A NetBox
token, a BMC password and a Redfish session are all in flight there. "The
segment is isolated" is a network control, not an authentication one — the
first thing an attacker on a node can do is read that traffic.

**Fix.** A lab CA, issued by the `netbox`/`sushy_emulator` roles, and TLS on
every management-plane listener: NetBox, the node API, the alert webhook, and
the Redfish endpoint. Verify the CA in `scripts/redfish.sh` and `seed.py`
rather than disabling verification. The Redfish side is the one to schedule
carefully: real BMC certificates are self-signed per vendor, so the client
needs a per-host trust store, not one CA.

**Effort.** 5–8 days.

**Status.** Not started.

---

## 2. No single head node

The head node is one WSL2 instance running NetBox, dnsmasq, warewulfd, the
git mirror, `slurmctld`, the node API, Prometheus, Alertmanager and `sushy`.
Losing it stops scheduling, provisioning and monitoring at once. Production
expects each of those to be its own failure domain.

### 2.1 `slurmctld` backup controller

**Gap.** One controller. `slurm.conf` has no `BackupController`, and there is
no second host to run it on.

**Why it matters.** When `slurmctld` dies, nothing schedules and nothing
drains. Slurm's own answer is a backup controller that takes over within
seconds and reads the same state from shared storage (`StateSaveLocation` on
NFS or a replicated filesystem). Without it, a controller crash is an outage
with a manual restart and a lost scheduling window.

**Fix.** A second head node, `StateSaveLocation` on shared storage from 5.6,
`BackupController=` and `SlurmctldParameters=...` in the rendered
`slurm.conf`, and a drill that kills the primary and proves the backup
answers. The config is already rendered by Ansible from NetBox, so the change
is a variable and an added host, not a rewrite.

**Effort.** 5–8 days, excluding the shared storage it depends on.

**Status.** Not started.

### 2.2 `slurmdbd` and MariaDB, rendered by Ansible — **built**

**Gap it closed.** The POC had no Slurm accounting at all: no `sacct`, no
`sreport`, no record of who ran what.

**Why it matters.** Accounting is the difference between a scheduler and a
scheduler you can operate. Fair-share (5.7), chargeback, usage reporting and
any "where did the jobs go" question all need it.

**Fix, as built.** A `slurm_accounting` role runs before `slurm_controller`
in `site.yml`: MariaDB on loopback with SchedMD's InnoDB settings, a
`slurmdbd` whose systemd start job ends only once it is listening, the
database password generated **on the head node** into
`/etc/cluster-lab/slurmdbd-db.password` (0600 root), `slurmdbd.conf` at 0600
owner `slurm`, `slurm.conf` switched to
`AccountingStorageType=accounting_storage/slurmdbd` and
`JobAcctGatherType=jobacct_gather/cgroup`, and idempotent `sacctmgr`
associations. `make slurm-ready` — and therefore `make demo` — now **fails
unless `sacct` shows every array task `COMPLETED 0:0` with its node**, so
accounting is on the acceptance path, not beside it.

**Effort.** Delivered.

**Status.** Built.

**Evidence.**
- PR [#9](https://github.com/dchau360/cluster-platform-wip/pull/9), merged to
  `main` as [`0ff16cc`](https://github.com/dchau360/cluster-platform-wip/commit/0ff16cc92559e263899f99f98f4971e175a19cc7).
- Drill, in two parts. CI runs a `molecule (slurm accounting)` scenario
  (Ubuntu 26.04 under systemd) through converge, idempotence with
  `changed=0`, and verify (units, ordering, file modes, associations). The
  lab run is the one `make slurm-ready` gates on: the branch was accepted on
  the lab with `make demo N=4` recording `sacct` for the whole array, not on
  `scontrol` alone ([`acceptance-drills.md`](acceptance-drills.md#measured-results)).
- The lab run earned its keep: turning accounting on for the first time on an
  existing lab hit `fatal: CLUSTER ID MISMATCH` — a `slurmctld` that had run
  without accounting had saved a self-assigned cluster ID, and `slurmdbd`
  assigned a different one. The fix,
  [`f0b7630`](https://github.com/dchau360/cluster-platform-wip/commit/f0b7630),
  clears only the stale `clustername` file when it names the same cluster and
  fails the play when it names a different one. The same acceptance re-run
  caught a second real defect — two roles set different modes on
  `/etc/cluster-lab`, so a re-converge was never a no-op; the fix,
  [`32512dc`](https://github.com/dchau360/cluster-platform-wip/commit/32512dc),
  is what makes the idempotence criterion hold. Both are in the same merge.

### 2.3 NetBox on managed Postgres with a tested restore

**Gap.** NetBox already runs on Postgres (`postgres:17-alpine`, with a
generated password, in the `netbox` role), so the database engine is right.
What is missing is everything around it: it runs in a Compose container on
the same host as NetBox, there is no backup on a schedule, and there has
never been a restore. NetBox is the source of truth for addresses, cabling
and Slurm topology, so an un-restorable NetBox is an un-restorable cluster.

**Why it matters.** "The source of truth" and "one container volume on one
host" cannot both be true in production. A restore you have not run is not a
backup.

**Fix.** Move Postgres to a managed or at least independently-operated
instance with its own lifecycle, take scheduled logical backups
(`pg_dump`/WAL or the platform's equivalent) off the head node, and make a
**tested restore** a CI or acceptance drill: restore the dump into a scratch
database, run `netbox/manage.py migrate --check` and `seed.py --check`, and
prove the renderers produce the same dnsmasq and `slurm.conf` output. Also
give NetBox a second instance behind a proxy so the IPAM read path survives a
head-node loss.

**Effort.** 5–8 days.

**Status.** Not started. Postgres is present; the HA, the backup and the
restore are not.

### 2.4 Replicated Warewulf and git mirror

**Gap.** One `warewulfd` serves every image and overlay, and one git mirror
publishes the `deployed` ref every node pulls. Both are single instances on
the head node, and [`scale-analysis.md`](scale-analysis.md) already measures
the image fan-out serialising at four nodes.

**Why it matters.** These are the boot path. If `warewulfd` or the mirror is
down, a rebooting node cannot come back and a rolling update cannot proceed.
At 100 nodes, one HTTP server fanning out 37.7 GiB is both a capacity limit
and an availability one.

**Fix.** Replicate the image store and the mirror, put them behind a load
balancer or a per-rack replica, and have Warewulf and the pull timer consume
the replicated endpoint. The scale analysis's cheaper option — a read-only
replica per rack — is the one to measure first (3.3). The git side is small:
the mirror is a bare repo and a second one behind the same name is enough.

**Effort.** 10–15 days.

**Status.** Not started.

---

## 3. Scale walls

This section follows the fix order in [`scale-analysis.md`](scale-analysis.md)
exactly. That document is the measurement; this is the production plan. The
first wall is behind us; the other four are in front.

### 3.1 Address plan that does not collide with the pool — **built**

**Gap it closed.** The old `/24` plan placed node 81 at `10.42.0.100`, inside
`dhcp-range=10.42.0.100,10.42.0.199`. The first scale failure was not
throughput. It was a node that is supposed to hold a reservation getting a
dynamic address, intermittently and hard to diagnose.

**Why it matters.** An address plan that fails at node 81 fails long before
performance does, and the symptom — an intermittently misnamed node — is the
worst kind to debug.

**Fix, as built.** The provisioning prefix is a `/22` in `netbox/definition.yml`.
BMC, provisioning and data each get a `/22`; node allocations start at host
offset 19 and span the first three `/24`s; the dnsmasq
dynamic/discovery pool is `10.44.3.20-10.44.3.250`, the final `/24`. The
seed records both the static ranges and the separate dynamic range, and the
harness renders its prefix, gateway, netmask and pool from that one
definition. Warewulf consumes each seeded node address from NetBox instead of
reproducing the formula.

**Effort.** Delivered.

**Status.** Built.

**Evidence.**
- PR [#11](https://github.com/dchau360/cluster-platform-wip/pull/11), merged
  to `main` as
  [`9a52d8e`](https://github.com/dchau360/cluster-platform-wip/commit/9a52d8ef33a761e22d33383bca9e203ee5a981f5)
  and promoted to `deployed`.
- Drill: `netbox/test_address_plan.py` allocates BMC, provisioning and data
  addresses for **N=100 and N=500** and asserts every address is inside its
  prefix and outside the dynamic pool. Its regression fixture reconstructs
  the old plan and proves node 81 lands inside `10.42.0.100-10.42.0.199`, so
  the test **fails on the old plan and passes on the new one**. It runs in CI.
- Lab drill: `make demo N=4` passed end to end from a clean `make down` on the
  new plan.

### 3.2 Power-on in waves of about ten

**Gap.** `make demo` powers every node on together; the harness has no wave
size. A hundred nodes powering on at once is a hundred `DHCPDISCOVER` bursts
at one `dnsmasq` and a hundred image fetches at one `warewulfd`.

**Why it matters.** [`scale-analysis.md`](scale-analysis.md) names the
simultaneous-DHCP failure mode as the one that *looks like broken hardware*:
a fraction of nodes retry past their PXE window and sit at an empty disk,
differently each time. Waves turn that from a correctness problem into a
throughput problem.

**Fix.** A wave parameter in the harness: power on (or promote) ten nodes,
wait for them to reach `active`, then the next ten. Redfish is already here,
so this is a loop and a wait condition, not a new subsystem. It also makes
failure modes 1 and 4 smaller at no extra component.

**Effort.** 2–3 days.

**Status.** Designed. The mechanism — Redfish power control via
`sushy-emulator` and a "wait for every node" primitive — already exists; only
the wave policy is missing.

### 3.3 Image fan-out load test

**Gap.** The 37.7 GiB-out-of-one-HTTP-server number is arithmetic over a
measured per-node cost, not an observation. The lab cannot run 100 nodes, so
the honest fix is not "buy bigger hardware", it is "run the load test with
throttled or synthetic clients".

**Why it matters.** The choice between multicast/BitTorrent distribution, a
caching proxy per leaf, and per-rack read-only replicas (2.4) should be made
on measured fan-out, not on intuition. [`scale-analysis.md`](scale-analysis.md)
explicitly refuses to guess here.

**Fix.** A load test against one `warewulfd`: drive N concurrent HTTP clients
for the image and overlays from the head node itself or from a synthetic
client pool, with a throttled uplink, and record the `overlay` phase and the
server's I/O and CPU. The same test measures the **second** boot, which is the
number that actually sets the rolling-update schedule.

**Effort.** 5–8 days.

**Status.** Not started.

### 3.4 Rolling-update concurrency policy

**Gap.** The rolling update is serial by design: drain one node, reimage,
reboot, wait for healthy, resume, next. Measured 211.9 s for four nodes,
projected **~1.2 hours at 100 nodes with an empty drain and ~1.8 hours with
real work to drain**. There is no knob for "how many nodes may be out at
once".

**Why it matters.** At four nodes, serial is correctness. At a hundred, an
update window measured in hours is a policy problem: the cluster is degraded
for the whole window, and an unplanned restart in the middle of it compounds.
The right answer is a fraction of the fleet that may be unavailable, chosen
on purpose.

**Fix.** An `max_unavailable`-style parameter that batches the update the same
way 3.2 batches power-on, with the drain/health wait per batch and a global
abort that leaves the already-updated nodes updated (the harness already
stops a rollout on the first failure). Document the chosen fraction and what
it does to the cluster's scheduling capacity. This depends on 3.2's wave
primitive.

**Effort.** 5–8 days.

**Status.** Not started. The mechanism (drain, reimage, health wait, resume,
rollback) is built; the concurrency policy is not.

### 3.5 Bulk NetBox seeding

**Gap.** `seed.py` makes **~17 sequential API calls per node at a measured
85 ms round trip**, which projects to ~145 s per converge at 100 nodes.

**Why it matters.** It is the smallest number on the scale page, and the
reason it is on the page at all is that it was measured rather than guessed —
it was assumed to be the dominant cost and it is not. It still grows with N
and it sits in the critical path of every converge.

**Fix.** Use NetBox's bulk endpoints, or parallelise the per-node calls with a
bounded pool, and add a seeding-time budget to `make demo`. If the bulk
endpoint cannot express the device/interface/address/cable fan-out, cache the
lookups that do not change between nodes.

**Effort.** 2–3 days.

**Status.** Not started.

---

## 4. Real hardware

The lab's "hardware" is QEMU guests and `sushy-emulator`. Power on/off/cycle
and persistent boot order are real against Redfish, which is why the boot path
is credible. Everything below the OS is where the emulator stops resembling a
datacentre, and it is disclosed as such in
[`redfish.md`](redfish.md) and [`scale-analysis.md`](scale-analysis.md).

### 4.1 Vendor BMC BIOS attributes

**Gap.** The lab sets boot order but no BIOS attributes. Real provisioning
sets them: hyperthreading, power profile, boot mode, SR-IOV, secure boot,
memory interleaving. Vendor implementations differ in attribute names, in the
pending/applied two-step and its reboot, in `@Redfish.Settings` semantics, and
in where they keep the current versus pending values.

**Why it matters.** A pipeline that can power a machine on but cannot put it
into a known, reproducible BIOS state produces a cluster whose nodes differ in
ways nothing records. Every "why is this node 15% slower" investigation ends
here.

**Fix.** A per-vendor BIOS profile in NetBox (or in the role), applied over
Redfish's `@Redfish.Settings` two-step: PATCH the pending settings, trigger
the apply job, wait for the reboot, then read the attribute back and assert
it. Fail provisioning if the attribute did not take. Test against at least
one real iDRAC and one real iLO before trusting it.

**Effort.** 5–10 days, plus access to two real vendors' hardware.

**Status.** Not started. This is also the second gap named in
[`scale-analysis.md`](scale-analysis.md#stated-plainly-what-is-untested-above-four-nodes).

### 4.2 VLANs

**Gap.** The lab is one bridge with no tagging. Production separates the
provisioning, management, data and storage networks into VLANs, and the
provisioning VLAN typically has stricter rules than the rest.

**Why it matters.** The lab's strongest security property is that the
provisioning segment has no uplink. On real hardware that property becomes
VLAN membership and ACLs, and if it is not modelled from the start, it gets
bolted on later with downtime.

**Fix.** Model the VLANs in NetBox, render the node and head-node interfaces
with 802.1Q sub-interfaces, and prove reachability across VLANs with the same
namespace technique `make verify-isolation` already uses. Keep the
no-uplink property as an explicit rule per VLAN.

**Effort.** 5–8 days.

**Status.** Not started.

### 4.3 Switch config from NetBox cabling

**Gap.** NetBox already models fabric ports and cables, and `seed.py` creates
them, so the topology is in the source of truth. Nothing consumes it to
configure a switch: there is no switch role, no template and no device
inventory beyond the BMC.

**Why it matters.** Cabling as documentation drifts; cabling that generates
the switch config cannot. This is the difference between NetBox as a record
and NetBox as the source of truth.

**Fix.** A switch template per platform (SNMP/SSH/NETCONF) rendered from
NetBox's interface and cable model, applied by an Ansible role, with a
dry-run/diff mode and a config-version check. Start with the access ports and
VLAN membership (4.2); uplinks and routing follow.

**Effort.** 10–15 days.

**Status.** Designed. The data model exists; the consumer does not.

### 4.4 LLDP validation

**Gap.** Nothing reads the actual neighbour topology. The cabling in NetBox is
asserted, not verified.

**Why it matters.** In production, a mis-cabled port is found by LLDP, not by
a human tracing a wire. LLDP validation also catches the case this repo cares
about most: a node plugged into the wrong VLAN.

**Fix.** Collect LLDP neighbours from the switch and from the node's own NIC
(where the firmware exposes it), compare against the NetBox cabling, and fail
the node or raise an alert on a mismatch. This is a natural companion to 4.3
and reuses the same collection channel.

**Effort.** 3–5 days.

**Status.** Not started.

### 4.5 InfiniBand subnet manager

**Gap.** The repo has real GUID discovery and DHCP option-61 client-id
reservations, exercised only against synthetic GUIDs, and RDMA is Soft-RoCE
over Ethernet. There is no IB fabric and no subnet manager.
([`ib-and-dhcp-option61.md`](ib-and-dhcp-option61.md),
[`rdma-soft-roce.md`](rdma-soft-roce.md).)

**Why it matters.** On a real HPC cluster, the IB fabric is where the
interconnect performance lives, and the subnet manager is a service the
cluster cannot run without. Excluding it would make this an Ethernet cluster
with an RDMA story.

**Fix.** Run `opensm` (or the vendor SM) on the head node or a dedicated
fabric node, give it the same systemd treatment as the other lab services,
and connect it to the GUID discovery that already exists. Prove it with
`ibstat` link-up and a `perftest` run on real hardware. The synthetic-GUID
code path is the part that needs replacing with a real sweep.

**Effort.** 5–8 days, plus real hardware.

**Status.** Not started.

---

## 5. Operations

A cluster you can build is not a cluster you can run. This is the shortest
list on the page and, in production, the one that pages people.

### 5.1 Alerting that reaches a receiver — **built**

**Gap it closed.** Prometheus existed, but nothing delivered an alert.

**Why it matters.** An alert rule that fires into a void is a dashboard.
Operations needs a notification path, a runbook and a test.

**Fix, as built.** An `alertmanager` role on the head node, wired to
Prometheus, with rules as code and `promtool` tests in CI: **StalePull** (a
node's convergence older than 2× the pull interval, or a failed pull),
**BurnInFailed** (a node held out of `active` by the gate), **NodeDown**
(`up == 0` for `node_exporter`), **SlurmctldDown** and a Slurm node
unavailable rule. Every rule carries a `runbook_url` into
[`operations.md`](operations.md). The receiver is a local webhook sink in the
lab, with the PagerDuty/Slack swap documented.

**Effort.** Delivered.

**Status.** Built.

**Evidence.**
- PR [#8](https://github.com/dchau360/cluster-platform-wip/pull/8), merged to
  `main` as
  [`6d62602`](https://github.com/dchau360/cluster-platform-wip/commit/6d62602b7118eb2a1444f220b8fa45a0c48c5932).
- CI: 22 successful checks on the tested head `d05d1df`, including
  `promtool check rules`, `promtool test rules` and `amtool check-config`.
- Live drills, with the full log in
  [`acceptance-drills.md`](acceptance-drills.md#alert-drills):
  - **NodeDown** — `cn04` healthy and `up == 1`, stopped with `virsh destroy`;
    `NodeDown` fired, reached the local webhook, and resolved after restart
    (fire `22:20:07Z`, resolve by `22:25:08Z`).
  - **StalePull** — `rack-a-u01`'s `last_converged_at` aged through the NetBox
    API; `StalePull` fired, reached the webhook, and resolved after the
    original value was restored (fire `22:25:08Z`, resolve by `22:28:39Z`).
  - `make demo N=4` on the rebased branch: four nodes joined Slurm, array 128
    completed four tasks `0:0`, one per node.

### 5.2 Central logs

**Gap.** Every service logs to its own journal on its own host. There is no
central store, no retention policy beyond the journal's default, and no way
to search across the head node and the nodes.

**Why it matters.** During an incident, "which node rebooted and why" means
reading N journals by hand. Production needs one searchable store with
retention, and nodes need to ship their logs somewhere that survives the node.

**Fix.** A log shipper on the head node and the nodes (Promtail/Vector or
`systemd-journal-remote`) into a central store (Loki, or the site's existing
ELK), with retention and a node-side buffer so a reboot does not lose the
lines that explain it. Add labels for node and unit so a query is
`{node="…",unit="slurmd"}`.

**Effort.** 3–5 days.

**Status.** Not started.

### 5.3 Change control with canaries

**Gap.** Change control is already unusually strong for a lab: nothing reaches
a node except through `make promote SHA=<commit>`, which refuses any commit
whose CI is not green, GitHub enforces the same required check on `deployed`,
and rollback is one measured ref move (2.95 s). What is missing is a
**canary**: a change reaches every node at once, on each node's next pull.
There is no "ten nodes first, watch, then the rest".

**Why it matters.** The blast radius of a bad commit on `deployed` is the
whole fleet. A canary turns "one typo takes the cluster down" into "one typo
takes ten nodes down and stops". The promotion gate protects against known
failure; the canary protects against unknown failure.

**Fix.** A canary stage in `promote.sh`: promote to a canary ref that only a
labelled subset of nodes follows, run `make convergence-status` and the
Prometheus rules against that subset for a bake window, then promote the rest.
The pull timer's splay already means nodes pick the ref up over minutes, so
the mechanism is a second ref and a subset, not a new delivery path.

**Effort.** 5–8 days.

**Status.** Change control: built. Canary: not started. See
[`tradeoffs.md`](tradeoffs.md#3-pull-versus-push) for the mechanism it builds
on.

### 5.4 On-call

**Gap.** There is no on-call rotation, escalation path, severity definition or
"who fixes this at 03:00" answer. Alerts fire to a lab webhook.

**Why it matters.** Alerting without ownership is noise. Production needs a
rotation, a paging provider, and an escalation policy that a new engineer can
read.

**Fix.** Define severities (page vs ticket), wire Alertmanager to the paging
provider (PagerDuty or Slack are both one receiver away from the lab webhook),
and write the rotation and escalation into the operations runbook. The rules
already carry runbook URLs, so this is policy and a receiver, not new
monitoring.

**Effort.** 2–3 days.

**Status.** Not started.

### 5.5 LDAP/SSSD identity

**Gap.** Users are a list in `ansible/group_vars/all.yml`
(`cluster_job_users`), created in Slurm by `sacctmgr`. There is no directory,
no SSO, no group mapping, and SSH access is keys-only on the head node.

**Why it matters.** A flat file is fine for a demo and wrong for a site: join,
leave and role changes become a PR. Production expects the cluster to consume
the organisation's directory, with group-to-account mapping and no local
account sprawl.

**Fix.** Join the head node and the nodes to LDAP/SSSD (or the site's IdP),
map directory groups to Slurm accounts, and have `sacctmgr` associations
rendered from the directory rather than from `group_vars`. Keep a break-glass
local account. Node login for users goes with it: `pam_slurm_adopt` on the
nodes, so a user can SSH only to a node running one of their jobs, with
`PrologFlags=Contain` on the controller. Today only root on the head node can
log in to a node (`node_sshd`, SRE-21); the Slurm image does not ship the
`slurm-pam_slurm` package yet.

**Effort.** 5–8 days.

**Status.** Not started.

### 5.6 Shared storage

**Gap.** There is no shared filesystem. Jobs run on local scratch, the
controller state is local, and there is no home directory that follows a user
between nodes. It is also the missing dependency for `slurmctld` state
(2.1), which needs `StateSaveLocation` on shared storage.

**Why it matters.** HPC is storage-shaped. Without a shared filesystem,
`sbatch` scripts cannot read their inputs on another node, users cannot see
their results, and the controller cannot fail over. It also underpins the
backup story.

**Fix.** Stand up a shared filesystem (NFS from a dedicated server for the
lab, or a parallel filesystem such as BeeGFS/Lustre where the workload needs
it) mounted at a fixed path on the head node and the nodes, with quotas and
per-user homes. Move `StateSaveLocation` and job scratch onto it.

**Effort.** 10–15 days.

**Status.** Not started.

### 5.7 Fair-share

**Gap.** Slurm accounting now records everything (2.2), but
`AccountingStorageEnforce` is not set and no fair-share weights exist. Users
can consume without limit; one user can starve the cluster.

**Why it matters.** Fair-share is the policy that makes a shared cluster
survive its users. It is also *cheap now* precisely because accounting is
built — the expensive part is already done.

**Fix.** Set `AccountingStorageEnforce=associations,limits,qos,safe` and a
`PriorityFlags`/`FairShareDampeningFactor` policy, give accounts and QOS a
weight in `sacctmgr`, and document the resulting behaviour in
[`operations.md`](operations.md#accounting). Decide the policy before enabling
enforcement, and roll it out with the canary from 5.3.

**Effort.** 2–3 days.

**Status.** Designed. Accounting is built; the enforcement policy is not set.

---

## The three that are done

| Item | Pull request | Merged as | Drill |
| --- | --- | --- | --- |
| Address plan for 500 nodes (§3.1) | [#11](https://github.com/dchau360/cluster-platform-wip/pull/11) | [`9a52d8e`](https://github.com/dchau360/cluster-platform-wip/commit/9a52d8ef33a761e22d33383bca9e203ee5a981f5) | `test_address_plan.py` fails on the old plan and passes at N=100/500; `make demo N=4` from clean `make down` |
| Slurm accounting, slurmdbd + MariaDB (§2.2) | [#9](https://github.com/dchau360/cluster-platform-wip/pull/9) | [`0ff16cc`](https://github.com/dchau360/cluster-platform-wip/commit/0ff16cc92559e263899f99f98f4971e175a19cc7) | Molecule scenario plus the `sacct` gate in `make slurm-ready`; the lab run caught and fixed the cluster-ID mismatch ([`f0b7630`](https://github.com/dchau360/cluster-platform-wip/commit/f0b7630)) |
| Alerting to a receiver (§5.1) | [#8](https://github.com/dchau360/cluster-platform-wip/pull/8) | [`6d62602`](https://github.com/dchau360/cluster-platform-wip/commit/6d62602b7118eb2a1444f220b8fa45a0c48c5932) | `promtool test rules` in CI; live NodeDown and StalePull drills firing and resolving through the receiver |

Everything else in this document is marked **designed** or **not started**
on purpose. Nothing here is called built that is not.

---

## If this had to ship, the order

The order is not the order of the sections. It is: remove the ways the
cluster loses data or credentials first, then the ways it loses availability,
then the ways it hits a wall, then hardware, then operations. It also front-
loads the cheapest high-severity items, because a superuser token on plain
HTTP is not a scale problem.

**Phase 0 — the ones that should not wait (2–3 weeks).** 1.2 least-privilege
token over TLS, 1.4 TLS on the management plane, 5.4 on-call, 5.7 fair-share,
3.5 bulk seeding. These are small, and each closes a finding that would
otherwise be the first thing a reviewer hits.

**Phase 1 — no single head node (4–6 weeks, partly parallel).** 2.3 NetBox on
managed Postgres with a tested restore, 5.6 shared storage, then 2.1 the
`slurmctld` backup controller, then 2.4 replicated Warewulf and mirror. The
storage item is on the critical path for the controller failover.

**Phase 2 — the scale walls, in the measured order (3–4 weeks).** 3.2 waves
of ten, 3.3 the image fan-out load test, 3.4 the rolling-update concurrency
policy, and revisit 2.4 with the load test's answer. The tests decide the
replication design; do not buy multicast before measuring it.

**Phase 3 — real hardware (4–7 weeks, hardware-dependent).** 4.1 vendor BIOS
attributes, 4.2 VLANs, 4.4 LLDP validation, 4.3 switch config from NetBox,
4.5 the IB subnet manager. This phase needs access to real kit and can run in
parallel with the phases above by a second engineer.

**Phase 4 — the long pole and the rest of operations (parallel).** 1.1 node
identity from attestation and 1.3 keys in Vault with rotation are the largest
items and should start early even though they finish last; 5.2 central logs,
5.3 canaries, 5.5 LDAP/SSSD fill in the operations gaps.

The aggregate is a quarter of work for one strong engineer with hardware
access, longer without it. The line that matters is not the total: it is that
**every item above is a named gap with a fix and a cost**, which is what a
hiring manager is actually asking for when they ask whether a lab would
survive production.

## Read next

* [`scale-analysis.md`](scale-analysis.md) — the measurements behind §3, and
  the order this document follows.
* [`tradeoffs.md`](tradeoffs.md) — the three decisions, each with the option
  not taken.
* [`operations.md`](operations.md) — the runbooks the alerts already link to.
* [`redfish.md`](redfish.md) and [`rdma-soft-roce.md`](rdma-soft-roce.md) —
  what the hardware emulation does and does not prove.
* [`case-study.md`](case-study.md) — the project in first person, including
  which of these gaps I would have designed for on day one.
