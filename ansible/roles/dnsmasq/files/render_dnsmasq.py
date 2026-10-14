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

The same entries also render a hosts(5) file, ``<ip> <name> <name>.<domain>``
for each node's provisioning address, so the head node resolves node names
from NetBox too. ``--etc-hosts`` copies that file into a marked block of
``/etc/hosts``. It reads only the rendered file, never NetBox, so it can run at
boot before NetBox is up: WSL rewrites ``/etc/hosts`` every time the
distribution starts, and scripts/net-up.sh puts the block back.

`pynetbox` is imported inside `main()` so the pure rendering function can be
unit-tested on a machine that has no NetBox client installed.
"""
import os
import sys
import stat
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


def render_hosts(entries, domain):
    """hosts(5) lines for each node's provisioning address.

    Only an entry with a MAC is the provisioning interface; an IB interface's
    address must not become a second answer for the node's name.
    """
    lines = []
    for entry in entries:
        hostname = entry.get("hostname")
        ip = entry.get("ip")
        if not hostname or not ip or not entry.get("mac"):
            continue
        names = [hostname, f"{hostname}.{domain}"] if domain else [hostname]
        lines.append(f"{ip}\t{' '.join(names)}\n")
    return sorted(set(lines))


HOSTS_BEGIN = "# BEGIN cluster-lab nodes, rendered from NetBox. Do not edit by hand.\n"
HOSTS_END = "# END cluster-lab nodes\n"


def merge_hosts_block(current, lines):
    """``current`` with the marked block replaced by ``lines``.

    The block is appended when absent, and everything outside it is kept as
    it is: the rest of /etc/hosts belongs to WSL or to the operator.
    """
    block = HOSTS_BEGIN + "".join(lines) + HOSTS_END
    start = current.find(HOSTS_BEGIN)
    end = current.find(HOSTS_END, start) if start != -1 else -1
    if start != -1 and end != -1:
        return current[:start] + block + current[end + len(HOSTS_END):]
    if current and not current.endswith("\n"):
        current += "\n"
    return current + block


def sync_etc_hosts(source, target):
    """Copy the rendered hosts file into ``target``'s marked block."""
    lines = source.read_text().splitlines(keepends=True) if source.exists() else []
    current = target.read_text() if target.exists() else ""
    merged = merge_hosts_block(current, lines)
    if merged == current:
        return False
    # In place, not by rename: /etc/hosts may be a bind mount.
    target.write_text(merged)
    return True


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


def write_output(target, lines):
    """Atomically install a dnsmasq-readable reservation file."""
    content = "".join(lines)
    if target.exists() and target.read_text() == content:
        if stat.S_IMODE(target.stat().st_mode) == 0o644:
            return False
        target.chmod(0o644)
        return True
    with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False) as out:
        out.writelines(lines)
        temporary = Path(out.name)
    temporary.chmod(0o644)
    temporary.replace(target)
    return True


def main(argv):
    hosts_file = Path(os.environ.get(
        "DNSMASQ_NETBOX_HOSTS_OUTPUT",
        "/var/lib/cluster-lab/dnsmasq/netbox-hosts"))
    if argv[1:] == ["--etc-hosts"]:
        target = Path(os.environ.get("ETC_HOSTS", "/etc/hosts"))
        print("changed" if sync_etc_hosts(hosts_file, target) else "unchanged")
        return

    import pynetbox  # imported here so the renderer can be tested alone

    nb = pynetbox.api(os.environ["NETBOX_URL"],
                      token=os.environ["NETBOX_TOKEN"])
    entries = netbox_entries(nb)
    target = Path(os.environ.get(
        "DNSMASQ_NETBOX_OUTPUT",
        "/var/lib/cluster-lab/dnsmasq/netbox-hosts.conf"))
    target.parent.mkdir(parents=True, exist_ok=True)
    # The hosts file is dnsmasq's only by location: dnsmasq does not read it,
    # so a change to it alone is no reason to restart dnsmasq.
    write_output(hosts_file, render_hosts(
        entries, os.environ.get("PROV_DOMAIN", "")))
    # Say whether anything changed, so the role restarts dnsmasq exactly when
    # the reservations moved. A renderer that always reported "unchanged"
    # left dnsmasq serving stale reservations until something else restarted it.
    print("changed" if write_output(target, render_entries(entries)) else "unchanged")


if __name__ == "__main__":  # pragma: no cover
    main(sys.argv)
