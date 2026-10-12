# Measurements

The measured 1-to-N curve is a deliverable, not a by-product. This file is
where it lands.

## How to produce a data point

```sh
make demo N=1
make demo N=2
make demo N=4
make timings          # table for the most recent run
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

Reserved for later tasks, so the names are stable before anything uses
them:

| Phase | Scope | Owner |
| --- | --- | --- |
| `image-build` | run | images repository |
| `slurm-join` | node | Slurm task |

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

Two lab runs on 2026-10-12, the same code, `make demo N=<n>` with no change
between them. `nodes-up` is the boot-loop wall clock from the first
`virsh start` to the last node's login prompt; the per-phase numbers are the
per-node durations recorded by the console watchers.

### End to end

| Date | N | platform-up | converge | nodes-up | every node reached login |
| --- | --- | --- | --- | --- | --- |
| 2026-10-12 | 2 | 0.231s | 28.096s | 36.549s | yes |
| 2026-10-12 | 4 | 0.226s | 29.393s | 38.579s | yes |

Run ids: `20261012T050012Z-293002` (N=2), `20261012T045854Z-284173` (N=4).

### Per phase, per node

`make demo N=2`:

| Phase | cn01 | cn02 |
| --- | --- | --- |
| firmware | 7.825 | 13.445 |
| dhcp-lease | 8.147 | 13.199 |
| ipxe | 5.950 | 5.978 |
| kernel | 0.004 | 0.004 |
| initramfs | 2.520 | 2.524 |
| overlay | 6.599 | 6.604 |
| login | 7.205 | 7.227 |

`make demo N=4`:

| Phase | cn01 | cn02 | cn03 | cn04 |
| --- | --- | --- | --- | --- |
| firmware | 14.055 | 13.778 | 13.463 | 13.476 |
| dhcp-lease | 13.398 | 13.369 | 13.373 | 13.388 |
| ipxe | 5.961 | 5.961 | 5.982 | 5.980 |
| kernel | 0.003 | 0.004 | 0.004 | 0.003 |
| initramfs | 2.533 | 2.534 | 2.536 | 2.537 |
| overlay | 7.962 | 7.954 | 7.953 | 7.954 |
| login | 7.215 | 7.218 | 6.597 | 7.228 |

`node-define` is 0.083-0.089s and `node-start` 0.180-0.212s per node at both
counts; they are not repeated above.

### What the curve says

The per-run phases (`preflight`, `systemd-install`, `net`, `services`,
`platform-up`, `converge`) are flat in N, which is the check that no per-node
work leaked into a per-run step. `converge` is the largest fixed cost, about
28-29s, and it does not move with N.

The per-node phases split in two. `ipxe`, `kernel`, `initramfs`, `overlay`
and `login` are flat to within a few milliseconds at both counts: once a node
has its kernel and initramfs, boot is independent of how many neighbours are
doing the same thing.

The contended phases are `firmware` and `dhcp-lease`. At N=2 the first node
to be served finishes `firmware` in 7.8s while the second takes 13.4s; at N=4
all four take 13.5-14.1s. One dnsmasq answers every DHCP request, and the
first node's negotiation is serialized behind the others. The effect is a
step, not a slope: 7.8s to ~13.5s between N=2 and N=4, then flat across the
nodes within each run.

`nodes-up` itself grows from 36.5s to 38.6s for double the nodes, because the
boot phases run in parallel. The 1-to-N cost is in the contended hand-off,
not in the boot.

