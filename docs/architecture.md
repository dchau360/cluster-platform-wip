# Architecture

## The shape of it

```text
                    Windows host
  +---------------------------------------------------------+
  |  WSL2, Ubuntu, systemd                                  |
  |                                                         |
  |   eth0  ---- NAT ----> home LAN        br-prov          |
  |   (never carries DHCP or TFTP)         (no uplink)      |
  |                                           |             |
  |   lab-dnsmasq.service  --- bound to ------+             |
  |     DHCP, DNS, TFTP                       |             |
  |                                           |             |
  |   libvirtd                                |             |
  |     node 1 .. node N  (OVMF, q35) --------+             |
  |                                                         |
  |   warewulf      (later)   node images, per-node overlays|
  |   netbox        (later)   source of truth               |
  |   slurm         (later)   controller on the host        |
  +---------------------------------------------------------+
```

Two networks, and they never meet. `eth0` is WSL's NAT interface; it
reaches the home LAN and carries no lab service. `br-prov` carries every
lab service and reaches nothing. See
[`network-isolation.md`](network-isolation.md).

## Boot path for one node

| Phase | Who serves it | Status |
| --- | --- | --- |
| Power on, UEFI firmware | OVMF via libvirt | working |
| DHCP discover, offer, lease | `lab-dnsmasq.service` | working |
| TFTP request for the boot file | `lab-dnsmasq.service` | working |
| GRUB, kernel and initramfs handoff | PXE task | stubbed |
| Image fetch and pivot | Warewulf | stubbed |
| Per-node overlay: host keys, Munge key, TLS | Warewulf overlay | stubbed |
| Slurm compute joins the controller | Slurm task | stubbed |

Each phase is a `phase_begin` / `phase_end` pair, per node. The phases
above the line record today; the ones below record as they are built, into
the same NDJSON stream. That is how the 1-to-N curve gets measured without
anyone retrofitting instrumentation.

## Where configuration comes from

One path, no exceptions.

```text
lab/local.env.example   defaults. tracked. host values blank.
        |
        v  overridden by
lab/local.env           real values. UNTRACKED.
        |
        v  loaded by
scripts/lib/common.sh   lab_load_env()
        |
        +--> harness scripts
        +--> systemd units       (rendered from systemd/*.in)
        +--> dnsmasq config      (generated into LAB_STATE_DIR)
        +--> Ansible             (group_vars/all.yml reads the environment)
```

Nothing reads a host value any other way. That is what makes the CI leak
gate meaningful: there is exactly one place for a host value to be, so a
value anywhere else is a bug by definition.

## Where state lives

Everything mutable is under `LAB_STATE_DIR`, outside the repository:

```text
$LAB_STATE_DIR/
  dnsmasq/lab.conf        generated config
  dnsmasq/hosts           generated static reservations, synthetic MACs
  dnsmasq/leases          live leases
  dnsmasq/dnsmasq.log     DHCP and TFTP log
  tftp/                   boot tree
  timings/<run>.ndjson    per-phase, per-node records
  timings/<run>.csv       the same, for the curve
  run/                    pid and change-counter files
  xml/<node>.xml          rendered libvirt domains

$LAB_VM_DIR/
  <node>.qcow2            node disk
  nvram/<node>.fd         per-VM UEFI variables
  console/<node>.log      serial console
```

None of it is in git, and `.gitignore` covers the shapes anyway, so an
accidental copy into the working tree is still not committable.

## Why a change counter

A provisioning harness that is not idempotent is a harness that cannot be
trusted to recover. Rather than asserting idempotency in prose, every
action in `scripts/lib/common.sh` reports `ok` or `changed`, `make up`
prints `RESULT: changed=N`, and `make verify-idempotent` fails if a second
run changes anything. It is cheap, and it catches the class of bug where a
step rewrites a file with a timestamp in it and quietly restarts a service
on every run.
