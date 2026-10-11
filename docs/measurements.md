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
| `dhcp-lease` | node | first DHCP lease on the isolated segment |

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
