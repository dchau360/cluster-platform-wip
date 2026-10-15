# InfiniBand GUID discovery and DHCP option-61

## The honest version first

**This lab has no InfiniBand hardware.** It is virtio NICs on one Linux
workstation. There is no HCA, no fabric, no subnet manager, and no real port
GUID anywhere in it. The code described here has never run against an IB
device, and no measurement in `docs/measurements.md` comes from one.

What *is* real is the code. `netbox/ib_guid.py` does the work it would do on
a machine that has an HCA:

- it reads port GUIDs from sysfs, the same files an IB-enabled kernel
  exposes (`/sys/class/infiniband/<device>/ports/<port>/gids/0` and
  `node_guid`);
- it turns a port GUID into the `dhcp-host=id:...` line dnsmasq needs for an
  option-61 (client-identifier) reservation;
- it is exercised by unit tests whose GUIDs are all synthetic.

This file exists so that gap is written down where an operator will find it
before relying on the code.

## What is measured, and what is assumed

| Fact | Status |
| --- | --- |
| sysfs layout for IB devices, ports and GIDs | Real kernel ABI. |
| Port GUID is the low 64 bits of GID 0 on an IB link | Real for IB; **not** for RoCE, where GID 0 is MAC-derived. |
| A client that identifies by option 61 sends its port GUID | **Assumed.** What an IPoIB DHCP client puts in option 61 depends on the client. Not validated on hardware. |
| The reservation produces a stable address on a real fabric | **Untested.** The lab cannot run this end to end. |

The third row is the one to keep in view. The code is written to a stated
convention, not to a measured one.

## The two halves

**Discovery** (`ib_guid.discover_ports`) walks the sysfs tree and returns,
per port, the device and port name, the node GUID, the port GUID (from an
explicit `port_guid` file when a driver exposes one, else the low half of
GID 0), the link state and the rate. A port whose GID is missing or all-zero
is reported with `port_guid: null`, because "this port has no usable GUID"
is itself a fact — and keying a reservation on an all-zero GUID would make
every uninitialized port match it.

**Reservation** (`ib_guid.reservation_line`) renders
`id:<client-id>,<ip>,<hostname>` in the configured `dhcp-hostsfile`.
`render_dnsmasq.py` reads an
interface's `ib_guid` custom field from NetBox and emits that line alongside
the MAC-keyed reservation it already produced for the provisioning
interface. The MAC path is unchanged and still keys only the provisioning
interface: a second MAC-keyed reservation for the same node would be a
second identity.

## Checking it

```sh
python3 -m unittest discover -s netbox -p 'test_*.py'
```

The tests build a small sysfs tree in a temporary directory and feed it
synthetic GUIDs (node `0200:0042:0000:0001`, port `0200:0042:0000:0002`).
The same tests on a machine with a real fabric would not change a line,
which is the point of keeping the conversion a pure function: the hardware
is the only untested part, and that is stated rather than implied.

CI runs the same command in the `python-tests` job.
