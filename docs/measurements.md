# Measurements

The measured 1-to-N curve is a deliverable, not a by-product. This file is
where it lands.

## How to produce a data point

```sh
make demo N=1
make demo N=2
make demo N=4
make timings          # table for the most recent run
make acceptance       # every count in ACCEPTANCE_NODE_COUNTS, then the drills
```

Each run writes `$LAB_STATE_DIR/timings/<run-id>.ndjson` and a `.csv`
sibling. One JSON object per phase per node:

```json
{"run":"20260101T120000Z-1234","n":2,"phase":"dhcp-lease","node":"cn01",
 "start":1760000000.123,"end":1760000004.456,"seconds":4.333,"status":"ok"}
```

NDJSON because it is append-only and survives a crash mid-run, and because
a partial file is still valid input to the next step.

## A phase that did not run says so

`status` is `ok`, `fail` or `skip`. A skipped phase has `"seconds":null` and
a `reason`, and `make timings` prints `-` for it and leaves it out of the
total:

```json
{"run":"...","n":2,"phase":"dhcp-lease","node":"cn01","seconds":null,
 "status":"skip","reason":"already running; no new lease expected"}
```

Null rather than 0, because 0 is a measurement and this is the absence of
one. A skipped phase recorded as 0.000 would quietly pull the mean down, and
the curve is the deliverable.

### Why `dhcp-lease` in particular

The phase is measured by watching for the node's MAC in the dnsmasq lease
file, so it is only honest if the lease it finds cannot be one from an earlier
run. Two rules follow, and both exist because the gate caught the harness
getting them wrong:

- A node that is **already running** will not ask for a new lease. Timing it
  would read the lease it already holds and report a few hundredths of a
  second. That node is skipped.
- A node that **is** about to boot has its old lease dropped first
  (`lease_forget` in `scripts/lib/common.sh`). `make nodes-down` without
  `WIPE=1` keeps the lease file, and that is the normal cheap way to cycle
  nodes, so this is the common path rather than an edge case.

Measured both ways on the lab host, at `N=2`. Reported as first and last
lease rather than by node name, because which node wins the race is not the
interesting part and naming them would not generalise to another `N`:

| `N=2` | first lease | last lease |
| --- | --- | --- |
| clean lease file | 5.104s | 6.115s |
| stale lease left, **before** the fix | 0.015s | 0.031s |
| stale lease left, **after** the fix | 5.109s | 6.121s |

The middle row is the one to remember. It reported `ok`.

The spread between first and last is the quantity the curve is made of, and
it only means anything once the measurement is real. At `N=4` on the same
host: 8.264s to 13.341s, against 5.104s to 6.115s at `N=2`.

## Phases

Recording today:

| Phase | Scope | What it covers |
| --- | --- | --- |
| `preflight` | run | tool, KVM, firmware and systemd checks |
| `systemd-install` | run | render and install the units |
| `net` | run | bridge, addressing, isolation rules, dnsmasq config |
| `services` | run | units enabled and active |
| `platform-up` | run | all of the above, as one phase |
| `node-define` | node | disk create, domain XML render, `virsh define` |
| `node-start` | node | `virsh start` to firmware handoff |
| `dhcp-lease` | node | first DHCP lease on the isolated segment, this boot |
| `firmware` | node | power-on through the UEFI PXE boot manager, to iPXE |
| `ipxe` | node | iPXE init, DHCP and the iPXE script fetch, to the kernel fetch |
| `kernel` | node | the kernel fetch |
| `initramfs` | node | the iPXE boot-menu wait and the initramfs fetch |
| `overlay` | node | the dracut stage: image, system and runtime overlay fetch + apply |
| `login` | node | pivot to the node root and systemd start, through the prompt |

From a login prompt to a node that can take work (SRE-8). A node arrives
`staged`, and `staged` means burn-in:

| Phase | Scope | What it covers |
| --- | --- | --- |
| `burnin-report` | node | the node's own burn-in run, until its measurements reach NetBox |
| `burnin-gate` | run | the head node judging every staged node and setting its status |
| `node-activate` | node | the power cycle of a promoted node, to the login prompt |
| `slurm-join` | node | `slurmd` registering with `slurmctld`, to a usable state |
| `job-array` | run | one task per node submitted, run and checked |
| `nodes-activate` | run | `burnin-report` + `burnin-gate` + `node-activate`, as one phase |
| `slurm-ready` | run | `slurm-join` + `job-array`, as one phase |

Acceptance work that is not part of `make demo`:

| Phase | Scope | What it covers |
| --- | --- | --- |
| `rdma-device` | run | both nodes of the pair reporting their RDMA device |
| `rdma-ib_write_bw` | run | the one-sided RDMA bandwidth benchmark |
| `rdma-ib_send_bw` | run | the two-sided RDMA bandwidth benchmark |
| `tcp-reference` | run | `iperf3` over the same link, for the only fair comparison |
| `cold-start-systemd` | run | systemd reaching `running` after the distribution restarts |
| `cold-start-units` | run | `lab-net` and `lab-dnsmasq` coming back unasked |
| `cold-start-up` | run | the idempotent `make up` after a cold start — the repair cost |
| `cold-start-nodes-up` | run | powering the nodes back on |
| `cold-start-slurm` | run | back to a cluster that takes work |

Reserved, so the name is stable before anything uses it:

| Phase | Scope | Owner |
| --- | --- | --- |
| `image-build` | run | images repository |

### How the boot phases are measured

`scripts/lib/boot-phases.sh` follows the node's serial console live and
records a phase when its marker appears. It is a live watcher rather than a
parse of the finished log because firmware and iPXE print no timestamps of
their own; only the wall clock at the moment a marker appeared gives them a
duration. The phase boundaries are the markers, in order: `iPXE initialising
devices`, `Downloading kernel image`, the kernel fetch's `ok`,
the initramfs fetch's `ok`, `warewulf: invoking /sbin/init`, and `login:`.

The console is per-boot: libvirt writes it from byte zero on every start,
so the watcher reads from zero after the harness clears it, and a node that
was already running is recorded as `skip` for every boot phase: it did not
boot this run, and timing a console it is not writing would be a measurement
of nothing. A boot that never reaches a marker is recorded with
`status=fail` on the phase it stalled in, after `BOOT_PHASE_TIMEOUT` seconds —
not silently dropped.

## What to look for in the curve

The interesting question is not how long one node takes. It is which
phases stay flat as N grows and which do not.

- Per-run phases (`net`, `image-build`) should be flat in N. If they are
  not, something per-node leaked into a per-run step.
- `node-define` should be close to linear and cheap.
- `dhcp-lease` and `image-fetch` are the contended ones: one dnsmasq and
  one image server answering N nodes at once. This is where the curve
  bends, and the shape of that bend is the actual result.

## Results

Three clean `make demo` runs on 2026-10-13, the same code at `5ab1a81`,
each from stopped nodes with every node re-staged so all of them run burn-in
and all of them are promoted through the gate. `nodes-up` is the boot loop
from the first `virsh start` to the last login prompt; the wall clock is the
whole demo, from `platform-up` to the job array. The per-phase numbers are
the per-node durations the console watchers recorded.

### End to end

| Date | N | platform-up | converge | nodes-up | nodes-activate | slurm-ready | wall clock |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-13 | 1 | 0.225s | 47.740s | 28.135s | 95.482s | 12.144s | 183.8s |
| 2026-10-13 | 2 | 0.211s | 47.415s | 29.342s | 126.176s | 12.150s | 215.3s |
| 2026-10-13 | 4 | 0.211s | 50.050s | 34.509s | 189.203s | 12.178s | 286.2s |

Run ids: `20261013T002040Z-699192` (N=1), `20261013T000117Z-678033` (N=2),
`20261013T000455Z-686422` (N=4).

### Per phase, per node — the first boot, to run burn-in

`make demo N=1`:

| Phase | cn01 |
| --- | --- |
| firmware | 5.250 |
| dhcp-lease | 6.051 |
| ipxe | 6.186 |
| kernel | 0.004 |
| initramfs | 2.487 |
| overlay | 6.800 |
| login | 7.106 |

`make demo N=2`:

| Phase | cn01 | cn02 |
| --- | --- | --- |
| firmware | 5.556 | 5.248 |
| dhcp-lease | 5.057 | 6.065 |
| ipxe | 5.872 | 6.182 |
| kernel | 0.004 | 0.004 |
| initramfs | 2.479 | 2.792 |
| overlay | 7.436 | 7.433 |
| login | 7.112 | 7.114 |

`make demo N=4`:

| Phase | cn01 | cn02 | cn03 | cn04 |
| --- | --- | --- | --- | --- |
| firmware | 5.579 | 5.572 | 5.576 | 5.572 |
| dhcp-lease | 5.092 | 5.078 | 6.091 | 6.092 |
| ipxe | 5.881 | 5.890 | 5.890 | 5.861 |
| kernel | 0.004 | 0.004 | 0.003 | 0.316 |
| initramfs | 2.784 | 3.104 | 2.479 | 2.474 |
| overlay | 11.241 | 11.869 | 11.844 | 11.861 |
| login | 7.409 | 7.103 | 7.429 | 7.417 |

`node-define` is 0.036-0.039s and `node-start` 0.147-0.176s per node at every
count; they are not repeated above.

### The second boot

Each demo boots every node twice. The first boot is at `staged`: the node
runs its own burn-in and posts the measurements, and the gate on the head
node judges them and sets the device `active`. Nobody can log in to a node to
start `slurmd`, so `nodes-activate` power-cycles a promoted node and its boot
pull sees `active`. That second boot is the one that puts `slurmd` up.

The second boot is not a repeat of the first for timing purposes; it is what
`node-activate` measures:

| `node-activate` | N=1 | N=2 | N=4 |
| --- | --- | --- | --- |
| cn01 | 28.475 | 28.454 | 30.502 |
| cn02 | | 30.492 | 28.498 |
| cn03 | | | 28.481 |
| cn04 | | | 28.492 |

`burnin-report` — the node's own burn-in, until its measurements reach
NetBox — was **61.4-67.3s per node at every count**, and it runs in parallel
across the nodes, so it does not grow with N within a run.

### What the curve says

The per-run phases (`preflight`, `systemd-install`, `net`, `services`,
`platform-up`, `converge`) are flat in N to within a couple of seconds:
`converge` is 47.4-50.1s and does not move. That is the check that no
per-node work leaked into a per-run step.

The DHCP lease is flat over this range too: 5.06-6.09s at N=2 and 5.08-6.09s
at N=4, with one dnsmasq answering all of them. This run does not reproduce
the lease step an earlier build showed (8.1s to 13.2s between N=2 and N=4);
saying so is more useful than asserting a contention the current build does
not show.

The per-node cost that does grow is `overlay`, the image and runtime-overlay
fetch and apply: **6.80s at one node, 7.44s at two, 11.24-11.87s at four**.
That is the warewulfd fan-out beginning to serialise, and it is the phase the
scale argument has to be built on — see [`scale-analysis.md`](scale-analysis.md).

`nodes-up` grows 28.1s → 29.3s → 34.5s, because the boot phases run in
parallel and only the hand-off contends. `slurm-ready` is 12.1-12.2s at every
count, because a node already registered is `skip`ped and only the last one
to join is measured (about 8.1s).

What grows linearly in N, and is not a contention effect, is the burn-in
acceptance path: `nodes-activate` is 95.5s for one node, 126.2s for two and
189.2s for four, dominated by each node's own ~61-67s burn-in plus its
~28-30s promotion power-cycle. That cost is per node and has to be planned
for separately from the boot curve.

### The previous measurement, kept for contrast

The 2026-10-12 runs against the pre-RDMA node image measured a much larger
boot spread: `firmware` 7.8s on the first node to 13.4s on the second, and
`dhcp-lease` flat at ~13.4s at N=4, with `nodes-up` 36.5s (N=2) and 38.6s
(N=4). Those numbers are real measurements of that build. They are kept here
because the difference between them and the 2026-10-13 curve is itself worth
noticing: the contended phases move with the image and the host state, and a
single afternoon of numbers should not be read as a property of the design.


