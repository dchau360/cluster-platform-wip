#!/usr/bin/env python3
"""Render dnsmasq reservations exclusively from NetBox interfaces/IPAM.

Two identifiers, two reservation styles, both from the source of truth:

* a MAC address, on the provisioning interface -> the classic
  ``<mac>,<ip>,<name>`` entry in a ``dhcp-hostsfile``;
* an InfiniBand port GUID, on any interface that carries one -> an
  option-61 (client-identifier) reservation,
  ``id:<client-id>,<ip>,<name>``.

The GUID path is real code exercised against **synthetic** GUID data only:
the lab has no InfiniBand hardware. See
docs/ib-and-dhcp-option61.md.

`pynetbox` is imported inside `main()` so the pure rendering function can be
unit-tested on a machine that has no NetBox client installed.
"""
import os
import tempfile
from pathlib import Path

from ib_guid import reservation_line


def render_entries(entries):
    """dnsmasq lines from plain entry mappings.

    Each entry is ``{"hostname", "ip", "mac", "ib_guid"}``. A MAC-based
    reservation is emitted only when the caller supplies a MAC (the
    provisioning interface does; an IB interface does not), and an
    option-61 reservation only when the GUID is usable.
    """
    lines = []
    for entry in entries:
        hostname = entry.get("hostname")
        ip = entry.get("ip")
        if not hostname or not ip:
            continue
        if entry.get("mac"):
            lines.append(f"{entry['mac']},{ip},{hostname}\n")
        guid_line = reservation_line(hostname, ip, entry.get("ib_guid"))
        if guid_line is not None:
            lines.append(guid_line)
    return sorted(set(lines))


def entry_hostname(address, device):
    """The OS hostname for a reservation.

    The address's DNS name is the node's hostname (`cn01`); the device name is
    its rack position (`rack-a-u01`). DHCP hands out the hostname. An address
    with no DNS name falls back to the device name, as before.
    """
    dns_name = (getattr(address, "dns_name", None) or "").strip()
    if dns_name:
        return dns_name.split(".")[0]
    return getattr(device, "name", None)


def reservation_address(addresses, interface_name):
    """Choose the authoritative address when discovery left an old lease.

    The provisioning address with a DNS name is the node identity seeded by
    the platform. Discovery can also leave a second, unnamed DHCP address on
    the interface; pynetbox does not promise result ordering, so blindly using
    the first address can perpetuate that temporary lease forever.
    """
    if interface_name == "provisioning":
        named = [address for address in addresses
                 if (getattr(address, "dns_name", None) or "").strip()]
        if named:
            return named[0]
    return addresses[0]


def netbox_entries(nb):
    """Every addressed interface, as a reservation entry."""
    entries = []
    for interface in nb.dcim.interfaces.all():
        addresses = list(nb.ipam.ip_addresses.filter(interface_id=interface.id))
        if not addresses:
            continue
        address = reservation_address(addresses, interface.name)
        ip = str(address.address).split("/")[0]
        device = getattr(interface, "device", None)
        custom = getattr(interface, "custom_fields", None) or {}
        entries.append({
            "hostname": entry_hostname(address, device),
            "ip": ip,
            # Only the provisioning interface keys on MAC. An IB interface
            # may report no 6-byte MAC at all, and a second MAC-keyed
            # reservation for the same node would be a second identity.
            "mac": interface.mac_address if interface.name == "provisioning" else None,
            "ib_guid": custom.get("ib_guid"),
        })
    return entries


def main():
    import pynetbox  # imported here so the renderer can be tested alone

    nb = pynetbox.api(os.environ["NETBOX_URL"],
                      token=os.environ["NETBOX_TOKEN"])
    lines = render_entries(netbox_entries(nb))
    target = Path(os.environ.get(
        "DNSMASQ_NETBOX_OUTPUT",
        "/var/lib/cluster-lab/dnsmasq/netbox-hosts.conf"))
    target.parent.mkdir(parents=True, exist_ok=True)
    # Say whether anything changed, so the role restarts dnsmasq exactly when
    # the reservations moved. A renderer that always reported "unchanged"
    # left dnsmasq serving stale reservations until something else restarted it.
    if target.exists() and target.read_text() == "".join(lines):
        print("unchanged")
        return
    with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False) as out:
        out.writelines(lines)
        temporary = out.name
    Path(temporary).replace(target)
    print("changed")


if __name__ == "__main__":  # pragma: no cover
    main()
