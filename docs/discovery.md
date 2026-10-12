# Discovery

A machine arrives with nothing but firmware. It has no name, no address in
the source of truth, and nobody typed its serial number into a spreadsheet.
The discovery image is how it introduces itself.

```text
  power on
     |
     v
  UEFI PXE (dnsmasq) -> iPXE -> warewulfd: discovery image
     |
     v
  boot the discovery image (same kernel, dracut and wwinit as any node)
     |
     v
  wwclient applies the cluster-discovery runtime overlay
     |  /etc/cluster-discovery/netbox.env   (URL + token, delivered at boot)
     v
  cluster-discovery.service
     |  scrape DMI, CPU, memory, NICs, disks, GPUs
     |  pynetbox: upsert device + custom fields
     |  pynetbox: upsert one interface per real NIC
     |  pynetbox: register the address it holds, assigned to the interface,
     |            and set it as the device's primary IPv4 address
     v
  NetBox record complete, console and journal carry the proof
```

## Why a separate image

The provisioned image should not know how to register machines. A node that
registers itself on every boot turns a one-time introduction into a recurring
write against the source of truth, and it would need the NetBox token on every
node forever. Discovery is a live boot with one job; the provisioned image
never sees the token.

The image is a layer on `compute-base`, so it boots through the exact same
kernel, dracut and `wwinit` initramfs path the provisioned image uses. That is
what makes "it boots" evidence about the boot chain and not about a second,
divergent image.

## The secret boundary

`cluster-discovery.service` reads two values:

```sh
NETBOX_URL=http://<provisioning-gateway>:8001
NETBOX_TOKEN=<a NetBox API token>
```

Neither is in the image and neither is in git. The Warewulf role reads them
from `/etc/cluster-lab/netbox.env` on the lab host, writes them into the
`cluster-discovery` runtime overlay, and `wwctl overlay build` serves that
overlay to the node at boot — the same mechanism that delivers the Munge key
and the SSH host keys.

The overlay is served over the provisioning segment without TLS or
authentication. That is acceptable only because the segment is isolated by
construction: `br-prov` has no uplink, and the nftables table drops anything
that tries to leave. See [`network-isolation.md`](network-isolation.md). A
production deployment would put a scoped, least-privilege token here rather
than the superuser token; this lab uses the one token NetBox ships with, and
says so.

## Why NetBox is exposed on the segment

The control host reaches the API at `127.0.0.1:8000`. A node cannot, so the
compose stack also publishes NetBox on `10.42.0.1:8001`:

```yaml
ports:
  - "127.0.0.1:8000:8080"           # control host: seeder and health checks
  - "10.42.0.1:8001:8080"           # provisioning segment: discovery
```

It binds the gateway address, never `0.0.0.0`, so the API does not appear on
the WSL NAT interface. sushy-emulator already owns `10.42.0.1:8000`, which is
why NetBox uses `8001`.

## What the node writes

The device name is the name the provisioning system already gave the node
(Warewulf sets the hostname). A machine defined nowhere falls back to its DMI
serial, so it still gets a deterministic name. Before creating a device, the
payload searches NetBox for one of the machine's MACs and adopts the device
that owns it, so a re-run updates rather than duplicates.

| Object | Fields set from the scrape |
| --- | --- |
| Device | `serial`, and the `discovered_*` custom fields below |
| Interface | one per non-loopback NIC: real name, real MAC, `mgmt_only` on the one holding the address |
| IP address | the address the node actually holds, assigned to that interface |

Custom fields (all text, so the same payload works against any NetBox
version):

`discovery_status`, `discovered_at`, `discovered_manufacturer`,
`discovered_product`, `discovered_serial`, `discovered_uuid`,
`discovered_bios`, `discovered_address`, `discovered_cpu_model`,
`discovered_cpu_count`, `discovered_memory_mib`, `discovered_disk_count`,
`discovered_disk_total_gb`, `discovered_gpu_count`, `discovered_gpu_models`,
`discovered_nic_macs`.

`discovery_status` is the success signal: `discovering` while the payload
runs, `complete` only after the address record exists.

## Running it

```sh
make discover                 # node 1
make discover NODE=cn02
```

The harness sets the node's image to `discovery` and appends the
`cluster-discovery` runtime overlay, power-cycles it through Redfish, polls
NetBox until the record reports `complete`, prints the record and the
`cluster-discovery:` lines from the node's serial console, then removes both
node-level overrides so a later boot is a provisioned image again.

It changes the node's image and one overlay, nothing else. Every system and
runtime overlay the default profile provides stays in place, so the discovery
boot is an ordinary boot of a different image.

Discovery does not reboot the node into a provisioned image. That transition
is part of the provisioning flow, not the introduction, and it is where a
server-side step belongs: the machine that just registered has no authority
to decide its own next image.

## Honesty

* The NetBox token is the lab's superuser token. A real deployment would use
  a scoped token that can write only `dcim` and `ipam` objects.
* The overlay is served unauthenticated over an isolated segment. The
  isolation is the control; it is not encryption.
* GPU presence is the PCI display class from `lspci`. A GPU that is present
  but bound to a host driver with no node-visible device file is still
  reported as present, because presence is what was asked for.
