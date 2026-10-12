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

Measured both ways on the lab host, to show the rules are load-bearing:

| | `cn01` | `cn02` |
| --- | --- | --- |
| clean lease file | 5.104s | 6.115s |
| stale lease left, **before** the fix | 0.031s | 0.015s |
| stale lease left, **after** the fix | 5.109s | 6.121s |

The middle row is the one to remember. It reported `ok`.

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

Reserved for later tasks, so the names are stable before anything uses
them:

| Phase | Scope | Owner |
| --- | --- | --- |
| `tftp-fetch` | node | PXE task |
| `grub-handoff` | node | PXE task |
| `image-build` | run | images repository |
| `image-fetch` | node | Warewulf task |
| `overlay-apply` | node | Warewulf task |
| `node-ready` | node | Warewulf task |
| `slurm-join` | node | Slurm task |

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
