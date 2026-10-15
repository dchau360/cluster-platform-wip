#!/usr/bin/env python3
"""Idempotently materialize the repository definition in NetBox."""
import argparse
import os
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pynetbox
import yaml

from address_plan import node_address, relocate


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


def ensure(endpoint, lookup, values, create_only=None):
    """Create or reconcile one object.

    `create_only` holds values written when the object is created and never
    compared afterwards. A device's status is the example: the seeder creates
    a node `staged`, and from then on the burn-in gate owns the field. A
    seeder that reset it on every converge would undo the gate's verdict.
    """
    obj = endpoint.get(**lookup)
    if obj is None:
        endpoint.create({**values, **(create_only or {})})
        return 1
    ignored = {"site", "rack", "device_type", "role", "manufacturer", "device", "object_types", "assigned_object_type", "assigned_object_id", "primary_mac_address"}
    changed = any(normalize(getattr(obj, key, "")) != normalize(value)
                  for key, value in values.items() if key not in ignored)
    if changed:
        obj.update(values)
        return 1
    return 0


def ensure_allocation(endpoint, description, values):
    """Reconcile one named IP allocation, removing pre-migration duplicates."""
    matches = [obj for obj in endpoint.filter(description=description)
               if normalize(getattr(obj, "description", "")) == normalize(description)]
    if not matches:
        endpoint.create(values)
        return 1
    changes = 0
    obj = matches[0]
    for duplicate in matches[1:]:
        duplicate.delete()
        changes += 1
    ignored = {"assigned_object_type", "assigned_object_id"}
    if any(normalize(getattr(obj, key, "")) != normalize(value)
           for key, value in values.items() if key not in ignored):
        obj.update(values)
        changes += 1
    return changes


def node_mac(index):
    """The MAC the harness gives node `index` (scripts/lib/common.sh node_mac).

    One formula, three readers: the harness that creates the VM, Warewulf's
    node definition, and this record. A record carrying a different MAC is a
    record the node can never be matched to.
    """
    oui = os.getenv("PROV_MAC_OUI") or "52:54:00"
    return f"{oui}:{(index >> 16) & 0xff:02x}:{(index >> 8) & 0xff:02x}:{index & 0xff:02x}".upper()


def ensure_primary_mac(nb, interface, mac):
    """Make `mac` the interface's primary MAC, keeping any others as history.

    NetBox 4.2+ models MACs as objects; an interface's `mac_address` is its
    primary one and is read-only. The NIC-swap drill adds MACs to the same
    interface on purpose, so the others are left alone.
    """
    changes = 0
    obj = nb.dcim.mac_addresses.get(mac_address=mac, assigned_object_type="dcim.interface",
                                    assigned_object_id=interface.id)
    if obj is None:
        obj = nb.dcim.mac_addresses.create({"mac_address": mac, "assigned_object_type": "dcim.interface",
                                            "assigned_object_id": interface.id})
        changes += 1
    current = getattr(interface, "primary_mac_address", None)
    if current is None or current.id != obj.id:
        interface.update({"primary_mac_address": obj.id})
        changes += 1
    return changes


def ensure_device(nb, name, site, rack, position, role, dtype):
    values = {"name": name, "site": site.id, "rack": rack.id, "position": position, "face": "front",
              "role": role.id, "device_type": dtype.id}
    changes = ensure(nb.dcim.devices, {"name": name}, values, create_only={"status": "active"})
    return changes, nb.dcim.devices.get(name=name)


def ensure_interface(nb, device, name):
    changes = ensure(nb.dcim.interfaces, {"device_id": device.id, "name": name},
                     {"device": device.id, "name": name, "type": "1000base-t"})
    return changes, nb.dcim.interfaces.get(device_id=device.id, name=name)


def ensure_cable(nb, a, b):
    """Cable interface `a` to interface `b`, replacing a cable to anything else."""
    peers = [getattr(p, "id", None) for p in (getattr(a, "link_peers", None) or [])]
    if a.cable is not None and peers == [b.id]:
        return 0
    for end in (a, b):
        if end.cable is not None:
            nb.dcim.cables.get(end.cable.id).delete()
    nb.dcim.cables.create({
        "a_terminations": [{"object_type": "dcim.interface", "object_id": a.id}],
        "b_terminations": [{"object_type": "dcim.interface", "object_id": b.id}],
        "status": "connected",
    })
    return 1


def ensure_fabric(nb, definition, site, node_count):
    """One leaf switch per rack, every leaf uplinked to one spine.

    This is the cabling Slurm's topology.conf is rendered from. The lab's
    nodes share one Linux bridge, so the fabric is synthetic, but it is real
    NetBox data: the renderer walks cables, not names, so a node recabled to
    another leaf moves in topology.conf with no code change.
    """
    fabric = definition.get("fabric")
    if not fabric:
        return 0
    changes = 0
    role = fabric["switch_role"]
    changes += ensure(nb.dcim.device_roles, {"slug": role["slug"]}, {**role, "color": "2196f3"})
    role_obj = nb.dcim.device_roles.get(slug=role["slug"])
    manufacturer = nb.dcim.manufacturers.get(slug="synthetic-lab")
    stype = fabric["switch_type"]
    changes += ensure(nb.dcim.device_types, {"slug": stype["slug"]},
                      {"model": stype["model"], "slug": stype["slug"], "manufacturer": manufacturer.id, "u_height": 1})
    stype_obj = nb.dcim.device_types.get(slug=stype["slug"])
    racks = [nb.dcim.racks.get(name=r["name"], site_id=site.id) for r in definition["racks"]]
    first = racks[0]
    delta, spine = ensure_device(nb, fabric["spine"], site, first, first.u_height - 1, role_obj, stype_obj)
    changes += delta
    for rack_index, rack in enumerate(racks, start=1):
        delta, leaf = ensure_device(nb, f"{fabric['leaf_prefix']}{rack.name}", site, rack, rack.u_height,
                                    role_obj, stype_obj)
        changes += delta
        delta, uplink = ensure_interface(nb, leaf, "uplink1")
        changes += delta
        delta, spine_port = ensure_interface(nb, spine, f"swp{rack_index}")
        changes += delta
        changes += ensure_cable(nb, uplink, spine_port)
    # Nodes are cabled to the leaf in their own rack, port = rack position.
    for index in range(1, node_count + 1):
        device = nb.dcim.devices.get(name=f"{first.name}-u{index:02d}")
        if device is None or device.rack is None:
            continue
        leaf = nb.dcim.devices.get(name=f"{fabric['leaf_prefix']}{device.rack.name}")
        node_port = nb.dcim.interfaces.get(device_id=device.id, name=fabric["node_interface"])
        delta, leaf_port = ensure_interface(nb, leaf, f"swp{int(device.position)}")
        changes += delta
        changes += ensure_cable(nb, node_port, leaf_port)
    return changes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--definition", default=Path(__file__).with_name("definition.yml"))
    parser.add_argument("--nodes", type=int, default=int(os.getenv("NODE_COUNT", "2")))
    args = parser.parse_args()
    # PROV_SUBNET moves the provisioning prefix; node_address() applies the
    # same move, so a record and the address the node holds always agree.
    definition = relocate(yaml.safe_load(Path(args.definition).read_text()), os.getenv("PROV_SUBNET"))
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
        # Description is the stable identity. Keying by CIDR would leave the
        # superseded /24 behind when the plan moves to a /22.
        changes += ensure(nb.ipam.prefixes, {"description": name}, {"prefix": cidr, "description": name, "status": "active", "is_pool": False})
    for name, address_range in definition["pools"].items():
        start, end = address_range.split("-")
        start, end = f"{start}/32", f"{end}/32"
        # Keyed on the description, not the start address: widening or moving a
        # pool is then an update of the range that already exists instead of a
        # second range left behind at the old start.
        description = f"{name} allocation pool"
        changes += ensure(nb.ipam.ip_ranges, {"description": description}, {"start_address": start, "end_address": end, "status": "active", "description": description, "mark_utilized": False})
    dynamic_start, dynamic_end = definition["address_plan"]["dynamic_pool"].split("-")
    description = "provisioning dynamic/discovery pool"
    changes += ensure(nb.ipam.ip_ranges, {"description": description},
                      {"start_address": f"{dynamic_start}/32", "end_address": f"{dynamic_end}/32",
                       "status": "active", "description": description, "mark_utilized": False})
    for field in definition["custom_fields"]:
        # Fields are declared as text for broad NetBox-version compatibility;
        # writers retain the typed semantics in their values. `object_types`
        # defaults to the device, because that is where convergence lands;
        # a field that belongs on an interface (the IB GUID) says so.
        # `netbox_type` overrides that for a field whose value is structured
        # data NetBox should store as such: the burn-in results are JSON so
        # the gate reads numbers, not a string it has to re-parse.
        values = {"name": field["name"], "label": field["name"].replace("_", " ").title(), "type": field.get("netbox_type", "text"), "object_types": field.get("object_types", ["dcim.device"]), "required": False}
        changes += ensure(nb.extras.custom_fields, {"name": field["name"]}, values)
    rack = nb.dcim.racks.get(name=definition["racks"][0]["name"], site_id=site_obj.id)
    role_obj = nb.dcim.device_roles.get(slug=role["slug"])
    dtype_obj = nb.dcim.device_types.get(slug=dtype["slug"])
    prefix = os.getenv("NODE_NAME_PREFIX") or "cn"
    domain = os.getenv("PROV_DOMAIN") or "lab.internal"
    # address_plan.py is shared with the harness; Warewulf then reads the
    # resulting provisioning address from NetBox rather than recomputing it.
    for index in range(1, args.nodes + 1):
        # Host identity is rack position; MAC replacement cannot rename it.
        hostname = f"{rack.name}-u{index:02d}"
        changes += ensure(nb.dcim.devices, {"name": hostname},
                          {"name": hostname, "site": site_obj.id, "rack": rack.id, "position": index, "face": "front", "role": role_obj.id, "device_type": dtype_obj.id},
                          create_only={"status": definition.get("new_device_status", "staged")})
        device = nb.dcim.devices.get(name=hostname)
        changes += ensure(nb.dcim.interfaces, {"device_id": device.id, "name": "provisioning"}, {"device": device.id, "name": "provisioning", "type": "1000base-t"})
        interface = nb.dcim.interfaces.get(device_id=device.id, name="provisioning")
        changes += ensure_primary_mac(nb, interface, node_mac(index))
        for network_name, cidr in definition["prefixes"].items():
            address = str(node_address(index, args.definition, network_name)) + "/" + cidr.split("/")[1]
            description = f"{network_name} for {hostname}"
            values = {"address": address, "status": "active", "description": description}
            if network_name == "provisioning":
                # The OS hostname is a property of the address the node holds,
                # which is where DNS would put it. The device name stays the
                # rack position; this is the one link between the two
                # namespaces, and the Slurm NodeName is read from it.
                values.update({"assigned_object_type": "dcim.interface", "assigned_object_id": interface.id,
                               "dns_name": f"{prefix}{index:02d}.{domain}"})
            # The description is the stable allocation identity. Looking up by
            # address would create a second record on a prefix migration and
            # leave dnsmasq free to select the stale reservation.
            changes += ensure_allocation(nb.ipam.ip_addresses, description, values)
    changes += ensure_fabric(nb, definition, site_obj, args.nodes)
    print(f"changed={changes}")


if __name__ == "__main__":
    main()
