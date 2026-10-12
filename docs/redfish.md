# Redfish

`sushy-emulator` (from the `sushy-tools` project) is the lab's Redfish
endpoint. It runs on the libvirt/KVM driver — the same path OpenStack
Ironic uses in its own CI — and gives the automation a management API for
the nodes: power on, power off, power cycle, and boot-order changes.

```text
   redfish.sh  ---Redfish/HTTP--->  sushy-emulator  ---libvirt--->  qemu/kvm
   (client)                         10.42.0.1:8000                    nodes
```

The endpoint is bound to the provisioning address only. It is not DHCP or
TFTP, but the lab holds one rule for every service: nothing lab-facing is
offered on an interface that can reach the home LAN.

## What is real, and what is not

This is the honesty line. Do not blur it.

| Capability | Real? | How it works |
| --- | --- | --- |
| Power on / off / cycle | **Yes** | `ComputerSystem.Reset` maps to a real libvirt `virsh start`/`destroy`. |
| Boot-order change | **Yes** | `BootSourceOverrideTarget` rewrites the libvirt domain's persistent per-device `<boot order=...>` elements. It takes effect on the next start. |
| System inventory | **Yes** | Domain name, UUID and power state come from libvirt. |
| BIOS attributes | **No** | The emulator reports a fixed synthetic set (`DEFAULT_BIOS_ATTRIBUTES` in sushy-tools). Nothing reads firmware, and nothing vendors report is exposed. |
| Secure boot | **No** | Not modelled. The guest uses the plain OVMF firmware the lab configures. |

A reviewer who finds a gap that was not disclosed stops trusting the
disclosed parts. The row that matters is **BIOS attributes**: Redfish has a
`Bios` resource, `sushy-emulator` answers it, and every value in it is a
constant. No lab claim depends on it.

## The interface the automation drives

`scripts/redfish.sh` is the stable client. It resolves a libvirt domain name
to its UUID (the Redfish Systems member Id) and then speaks Redfish:

```sh
scripts/redfish.sh list                    # every exposed system
scripts/redfish.sh status cn01             # power state and boot override
scripts/redfish.sh power cn01 cycle        # On | off | cycle
scripts/redfish.sh boot  cn01 pxe          # pxe | hd | cd | http
```

`power` and `boot` are the two calls the node power/boot automation needs.
`boot` also prints the persistent libvirt boot order it produced, so the
caller can see the change rather than take it on faith.

## Verified on the lab

`make redfish-demo` runs the sequence and prints it. Against `cn01`:

```text
$ scripts/redfish.sh power cn01 cycle
changed: redfish cn01 power cycle (ForceRestart)
$ scripts/redfish.sh boot cn01 hd
changed: redfish cn01 boot hd (Hdd); libvirt boot order: <boot order='1'/> (disk)
$ scripts/redfish.sh boot cn01 pxe
changed: redfish cn01 boot pxe (Pxe); libvirt boot order: <boot order='2'/> (disk) <boot order='1'/> (interface)
```

The last two lines are the point: the network interface moves to boot order
1 for PXE, and the disk moves to order 1 for HDD. The change is in the
domain's persistent configuration, so it survives a restart.

## Configuration

`ansible/roles/sushy_emulator` installs and runs it. The address and port
come from the provisioning segment, so there is no host value to configure:

| Variable | Meaning |
| --- | --- |
| `SUSHY_EMULATOR_PORT` | TCP port on the provisioning address. Default 8000. |
| `SUSHY_EMULATOR_LISTEN_IP` | The provisioning gateway address, from `PROV_GW`. |
| `SUSHY_EMULATOR_LIBVIRT_URI` | `qemu:///system`, from `LIBVIRT_URI`. |

The Flask server sushy-tools ships is a development server. That is
adequate for a lab of a handful of nodes and is not a claim of production
readiness; a real deployment puts it behind gunicorn.
