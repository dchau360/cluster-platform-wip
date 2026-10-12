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

The console is opened `append=on`, so the watcher starts from the file size
recorded before `virsh start` and reads only the bytes this boot appended. A
node that was already running is recorded as `skip` for every boot phase: it
did not boot this run, and timing the console it is not writing would be a
measurement of nothing. A boot that never reaches a marker is recorded with
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

| Date | N | Total | Notes |
| --- | --- | --- | --- |
| _pending_ | | | First curve lands when the PXE and Warewulf phases record. |

The foundation task deliberately does not publish a curve. Timing three
phases would produce a number with no meaning. The harness, the phase
names and the output format are in place so the first real curve needs no
new instrumentation.
