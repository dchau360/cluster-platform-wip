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
| TFTP request for the iPXE boot file | `lab-dnsmasq.service` | working |
| iPXE script, kernel and initramfs | `warewulfd` over HTTP on `br-prov` | working |
| Image fetch, overlay apply, pivot | Warewulf, two-stage `dracut` | working |
| Per-node overlay: SSH host keys, Munge key | Warewulf runtime overlay | working |
| Discovery: scrape and self-register in NetBox | `cluster-discovery` runtime overlay + `discovery` image | working |
| Slurm compute joins the controller | Slurm task | stubbed |

"Working" means observed end to end on the lab host: a q35/OVMF node
PXE-boots, iPXE fetches its script from `http://10.42.0.1:9873`, loads the
kernel and the `wwinit` initramfs, pivots into the provisioned image, and
reaches a login prompt. The runtime overlay delivers the cluster Munge key
and per-node SSH host keys; neither is in git or in an image layer.

Two things about the Warewulf half are worth recording because they are
configuration, not code, and both cost time to find:

* The server is built from source with the default prefix, so `wwctl` reads
  `/usr/local/etc/warewulf/warewulf.conf` and writes state under
  `/var/local/warewulf`. The packaged paths (`/etc/warewulf`,
  `/var/lib/warewulf`) are not used.
* The Ubuntu `ipxe` package has no `imgextract` command, which is a
  Warewulf patch. The node tag therefore selects the two-stage `dracut`
  method, and the node image must ship an initramfs built with the
  `wwinit` dracut module. `cluster-images-wip` builds that in; without it
  the node stops at `Failed to mount /sysroot`.

Each phase is a `phase_begin` / `phase_end` pair, per node. The phases
above the line record today; the ones below record as they are built, into
the same NDJSON stream. That is how the 1-to-N curve gets measured without
anyone retrofitting instrumentation.

## Discovery

An image that has no identity yet can boot a second image whose only job is
to describe it. `make discover` switches a node to the `discovery` image and
appends the `cluster-discovery` runtime overlay for one boot; the payload
scrapes DMI, CPU, memory, NICs, disks and GPUs and writes its own NetBox
device, interfaces and IPAM address. The NetBox endpoint and token arrive in
the overlay at boot, never in an image or in git. See
[`discovery.md`](discovery.md).

## The management plane

Power and boot order are driven over Redfish by `sushy-emulator` on the
libvirt/KVM driver, the path OpenStack Ironic uses in its own CI. It binds
to the provisioning address only, and `scripts/redfish.sh` is the client
the node power/boot automation calls:

```text
redfish.sh  --Redfish/HTTP-->  sushy-emulator (10.42.0.1:8000)  --libvirt-->  qemu/kvm
```

Real power on/off/cycle and real persistent boot-order changes. **Not**
vendor BIOS attributes: the emulator reports a fixed synthetic set. See
[`redfish.md`](redfish.md) for the capability table; the line between the
two is written down on purpose.

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

Warewulf keeps its own tree, because `wwctl` owns it and not the `make`
harness. It is outside both repositories, and the Munge key inside it is
the one piece of state that must never be copied into either:

```text
$WAREWULF_STATE_ROOT/            /var/local/warewulf
  chroots/<image>/               imported node image (kernel, initramfs with wwinit)
  overlays/<name>/rootfs/        site overlays; cluster-identity holds the Munge key
  provision/images/              built squashfs served to nodes
  provision/overlays/<node>/     per-node runtime and system overlay images
  tftpboot/warewulf/             iPXE binaries served by dnsmasq

/etc/cluster-lab/
  munge.key                      generated once, 0400 root, untracked
  netbox.env                     NetBox runtime secrets, 0600 root
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
