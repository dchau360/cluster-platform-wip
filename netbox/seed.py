#!/usr/bin/env python3
"""Idempotently materialize the repository definition in NetBox."""
import argparse
import ipaddress
import os
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pynetbox
import yaml


def normalize(value):
    """Normalize pynetbox's display objects and decimalized API numbers."""
    if hasattr(value, "value"):
        value = value.value
    if isinstance(value, bool) or value is None:
        return value
    text = str(value).lower()
    try:
        return Decimal(text).normalize()
    except InvalidOperation:
        return text


def ensure(endpoint, lookup, values):
    obj = endpoint.get(**lookup)
    if obj is None:
        endpoint.create(values)
        return 1
    ignored = {"site", "rack", "device_type", "role", "manufacturer", "device", "object_types", "assigned_object_type", "assigned_object_id"}
    changed = any(normalize(getattr(obj, key, "")) != normalize(value)
                  for key, value in values.items() if key not in ignored)
    if changed:
        obj.update(values)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--definition", default=Path(__file__).with_name("definition.yml"))
    parser.add_argument("--nodes", type=int, default=int(os.getenv("NODE_COUNT", "2")))
    args = parser.parse_args()
    definition = yaml.safe_load(Path(args.definition).read_text())
    nb = pynetbox.api(os.environ["NETBOX_URL"], token=os.environ["NETBOX_TOKEN"])
    changes = 0
    site = definition["site"]
    changes += ensure(nb.dcim.sites, {"slug": site["slug"]}, site)
    site_obj = nb.dcim.sites.get(slug=site["slug"])
    for rack in definition["racks"]:
        values = {**rack, "site": site_obj.id}
        changes += ensure(nb.dcim.racks, {"name": rack["name"], "site_id": site_obj.id}, values)
    role = definition["device_role"]
    changes += ensure(nb.dcim.device_roles, {"slug": role["slug"]}, {**role, "color": "4caf50"})
    maker = definition["device_type"]["manufacturer"]
    changes += ensure(nb.dcim.manufacturers, {"slug": "synthetic-lab"}, {"name": maker, "slug": "synthetic-lab"})
    manufacturer = nb.dcim.manufacturers.get(slug="synthetic-lab")
    dtype = definition["device_type"]
    changes += ensure(nb.dcim.device_types, {"slug": dtype["slug"]}, {"model": dtype["model"], "slug": dtype["slug"], "manufacturer": manufacturer.id, "u_height": 1})
    for name, cidr in definition["prefixes"].items():
        changes += ensure(nb.ipam.prefixes, {"prefix": cidr}, {"prefix": cidr, "description": name, "status": "active", "is_pool": False})
    for name, address_range in definition["pools"].items():
        start, end = address_range.split("-")
        start, end = f"{start}/32", f"{end}/32"
        # Keyed on the description, not the start address: widening or moving a
        # pool is then an update of the range that already exists instead of a
        # second range left behind at the old start.
        description = f"{name} allocation pool"
        changes += ensure(nb.ipam.ip_ranges, {"description": description}, {"start_address": start, "end_address": end, "status": "active", "description": description, "mark_utilized": False})
    for field in definition["custom_fields"]:
        # Device convergence fields are declared as text for broad NetBox-version
        # compatibility; writers retain the typed semantics in their values.
        values = {"name": field["name"], "label": field["name"].replace("_", " ").title(), "type": "text", "object_types": ["dcim.device"], "required": False}
        changes += ensure(nb.extras.custom_fields, {"name": field["name"]}, values)
    rack = nb.dcim.racks.get(name=definition["racks"][0]["name"], site_id=site_obj.id)
    role_obj = nb.dcim.device_roles.get(slug=role["slug"])
    dtype_obj = nb.dcim.device_types.get(slug=dtype["slug"])
    for index in range(1, args.nodes + 1):
        # Host identity is rack position; MAC replacement cannot rename it.
        hostname = f"{rack.name}-u{index:02d}"
        changes += ensure(nb.dcim.devices, {"name": hostname}, {"name": hostname, "site": site_obj.id, "rack": rack.id, "position": index, "face": "front", "role": role_obj.id, "device_type": dtype_obj.id, "status": "active"})
        device = nb.dcim.devices.get(name=hostname)
        changes += ensure(nb.dcim.interfaces, {"device_id": device.id, "name": "provisioning"}, {"device": device.id, "name": "provisioning", "type": "1000base-t", "mac_address": f"02:00:00:42:{index // 256:02x}:{index % 256:02x}"})
        interface = nb.dcim.interfaces.get(device_id=device.id, name="provisioning")
        for network_name, cidr in definition["prefixes"].items():
            address = str(ipaddress.ip_network(cidr)[19 + index]) + "/" + cidr.split("/")[1]
            values = {"address": address, "status": "active", "description": f"{network_name} for {hostname}"}
            if network_name == "provisioning":
                values.update({"assigned_object_type": "dcim.interface", "assigned_object_id": interface.id})
            changes += ensure(nb.ipam.ip_addresses, {"address": address}, values)
    print(f"changed={changes}")


if __name__ == "__main__":
    main()
