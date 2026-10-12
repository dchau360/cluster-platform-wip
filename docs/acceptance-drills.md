# Acceptance drills

Four operational criteria that a boot chain can be built without ever
proving. Each is a command, not a checklist, and each leaves the evidence on
the console it ran on.

| Criterion | Command | What proves it |
| --- | --- | --- |
| #6 rollback to the previous image | `make rollback TAG=sha-<previous>` | the booted node reports the older tag |
| #8 the same code boots N=2 and N=4 | `make demo N=2` / `N=4` | the per-phase timing table |
| #7 one node re-provisions alone | `make drill-reprovision` | neighbours' CPU time and consoles keep going |
| #3 identity survives a NIC swap | `make drill-nic-swap` | hostname and NetBox device unchanged, MAC changed |

`make acceptance` runs all four in order. It needs `TAG=` for the rollback
and stops at the first failure, so a partial record cannot be mistaken for a
complete one.

## #6 — one-command rollback

Every image traces to an Actions run and a GHCR tag. The tag is the only
thing a rollback changes:

```sh
make rollback TAG=sha-1bb6b9f6f98e
```

Under the hood, and still one command:

1. `WAREWULF_IMAGE_TAG` is set to the pinned tag and the Warewulf role runs.
   The role re-imports `docker://ghcr.io/dchau360/cluster-images-wip/compute-slurm:<tag>`
   (no credential; the packages are public) and rebuilds the runtime overlays.
2. The node is stopped, started, and its boot watched to the login prompt.
3. The `image-reference` line the in-node identity check writes to the serial
   console is read back and compared to the tag that was asked for.

The tag is pinned on purpose. `latest` names whatever was pushed most
recently, which is exactly what a rollback must not do.

The node reports the tag because the platform delivers it in the same runtime
overlay as the identity material
(`/etc/cluster-lab/image-reference`, written by `warewulf_server` from
`warewulf_server_image_uri`). That makes "roll back, reboot, read the version
back" a closed loop instead of one that depends on a human remembering what
was imported.

## #8 — N=2 and N=4 from the same code

```sh
make demo N=2
make demo N=4
```

Nothing in either repository knows a node count: CI fails on a literal
`NODE_COUNT` assignment, a literal loop bound, or a hardcoded node-name list.
The two runs differ only in the value of `N`.

The timing table is the deliverable. `make timings` renders the most recent
run; `docs/measurements.md` holds the curve. The phases and their boundaries
are documented there.

## #7 — one node re-provisions, the others do not move

```sh
make drill-reprovision NODE=1
```

The target is torn down to a blank disk: powered off, undefined, and its
qcow2 removed. `nodes-up.sh` then takes it through the full provisioning path
again while every other node is left alone.

"It looked fine" is not evidence. The drill records, for each neighbour,
before and after:

- `virsh domstate` — must stay `running`
- the libvirt domain id — must be the same domain, not redefined and
  recreated
- QEMU CPU time (`virsh domstats --cpu-total`) — must increase, because a
  guest that restarted would reset it
- the serial console — must not be truncated
- the DHCP lease — must still be present

The re-provisioned node is the control: its disk, domain id and CPU time all
reset.

## #3 — identity survives a NIC swap

```sh
make drill-nic-swap NODE=1
```

The node's virtual NIC MAC is replaced with a different locally-administered
address, and the new address is registered where a provisioned node is
described: Warewulf's node record (the address-to-node mapping), the NetBox
interface, and therefore the dnsmasq reservations rendered from NetBox. Then
the node reboots.

What must not change is the name:

- the console login prompt still reads `cn01`
- the DHCP lease still records `cn01`
- the NetBox device is still keyed by rack position — `rack-a-u01` — even
  though the interface's MAC now holds the new address

That is the design the seed states and this drill checks: host identity is
rack position; a MAC is a locator that can be replaced.

## Measured results

All four drills ran on the lab host on 2026-10-12 against
`cluster-platform-wip` at the merge that added them.

### #6 rollback

```
$ make rollback TAG=sha-1bb6b9f6f98e
...
server imported marker : sha-1bb6b9f6f98e
node cn01 reports : docker://ghcr.io/dchau360/cluster-images-wip/compute-slurm:sha-1bb6b9f6f98e
ROLLBACK OK — cn01 reports the rolled-back tag sha-1bb6b9f6f98e
```

The marker before the command was `latest`. The run took 56s, of which 28.8s
was the converge (image import) and 27.5s the reboot and boot.

### #8 N=2 and N=4

```
$ make demo N=2     # nodes-up 36.549s, both nodes reached login
$ make demo N=4     # nodes-up 38.579s, all four nodes reached login
```

The per-phase tables and the curve are in
[`measurements.md`](measurements.md#results).

### #7 one node re-provisions alone

```
$ make drill-reprovision NODE=1
after
cn02 state=running domid=20 cpu_ns=30612511000 console_bytes=10019 lease=1
ok   cn02: state=running domid 20->20 cpu_ns 29572300000->30612511000 lease=1
RE-PROVISION OK — cn01 was rebuilt from bare metal; every neighbour stayed up
```

`cn01` is the control: its disk was removed, so its domain id and CPU time
both reset. `cn02`'s domain id is unchanged and its CPU time grew across the
window, so it was running the whole time.

### #3 identity survives a NIC swap

```
$ make drill-nic-swap
pre-swap identity for cn01 (index 1)
domain MAC          : 52:54:00:00:00:01
warewulf hwaddr     : 52:54:00:00:00:01
netbox device       : rack-a-u01 (position 1.0, id 1)
netbox interface MAC: 02:00:00:42:00:01
swap: 52:54:00:00:00:01 -> 52:54:00:00:ff:01, re-register the same identity
post-swap identity
domain MAC          : 52:54:00:00:ff:01
netbox device       : rack-a-u01 (position 1.0)
netbox interface MAC: 52:54:00:00:FF:01
console             : cn01 login:
dhcp lease hostname : cn01
PASS the MAC changed: 52:54:00:00:ff:01
PASS NetBox recorded the new MAC: 52:54:00:00:ff:01
PASS the NetBox device kept its name: rack-a-u01
PASS the hostname did not change: cn01
PASS the node still booted as itself: cn01 login:
NIC SWAP OK
```

The MAC moved through Warewulf, NetBox and the dnsmasq reservations, and the
node rebooted. Its name did not move.
