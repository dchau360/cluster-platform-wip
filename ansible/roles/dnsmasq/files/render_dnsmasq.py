#!/usr/bin/env python3
"""Render dnsmasq reservations exclusively from NetBox interfaces/IPAM."""
import os
import tempfile
from pathlib import Path
import pynetbox

nb = pynetbox.api(os.environ["NETBOX_URL"], token=os.environ["NETBOX_TOKEN"])
lines = []
for interface in nb.dcim.interfaces.filter(name="provisioning"):
    addresses = list(nb.ipam.ip_addresses.filter(interface_id=interface.id))
    if interface.mac_address and addresses:
        ip = str(addresses[0].address).split("/")[0]
        lines.append(f"dhcp-host={interface.mac_address},{interface.device.name},{ip}\n")
target = Path(os.environ.get("DNSMASQ_NETBOX_OUTPUT", "/var/lib/cluster-lab/dnsmasq/netbox-hosts.conf"))
target.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False) as output:
    output.writelines(sorted(lines))
    temporary = output.name
Path(temporary).replace(target)
