#!/usr/bin/env python3
"""Read NetBox and print the Slurm model the slurm_config templates render.

Every node line, every switch line and every GRES line in the controller's
configuration comes from here, and every value here comes from NetBox:

  node name        the DNS name on the device's provisioning address
  NodeAddr         that address
  CPUs, memory     the discovery custom fields the node wrote about itself
  GPUs             the discovered GPU count
  switches         dcim cables: node -> leaf, leaf -> spine

Only `active` compute devices become Slurm nodes. A `staged` node is in
burn-in; the gate makes it `active`, and the next render adds it.

Nothing is defaulted. A node NetBox does not fully describe is an error that
names the node and the missing field, because a guessed CPU count is a
hand-written value with extra steps.

Standard library only.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request


class ModelError(ValueError):
    """NetBox does not describe the cluster completely."""


def _value(field):
    if isinstance(field, dict) and "value" in field:
        return field["value"]
    return field


def _int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def build_model(devices, addresses, interfaces, *, compute_role="compute",
                switch_role="switch", mem_reserve_mib=0):
    """Pure: NetBox objects in, Slurm model out."""
    by_id = {d["id"]: d for d in devices}
    role_of = {d["id"]: (d.get("role") or {}).get("slug") for d in devices}

    names = {}
    for addr in addresses:
        dns = (addr.get("dns_name") or "").strip()
        device = ((addr.get("assigned_object") or {}).get("device") or {}).get("id")
        if dns and device is not None:
            names[device] = (dns.split(".")[0], addr["address"].split("/")[0])

    problems = []
    nodes = []
    for device in sorted(devices, key=lambda d: d["name"]):
        if role_of[device["id"]] != compute_role or _value(device.get("status")) != "active":
            continue
        custom = device.get("custom_fields") or {}
        hostname, address = names.get(device["id"], (None, None))
        cpus = _int(custom.get("discovered_cpu_count"))
        memory = _int(custom.get("discovered_memory_mib"))
        gpus = _int(custom.get("discovered_gpu_count")) or 0
        missing = [field for field, value in (("dns_name", hostname), ("discovered_cpu_count", cpus),
                                              ("discovered_memory_mib", memory)) if not value]
        if missing:
            problems.append(f"{device['name']}: missing {', '.join(missing)}")
            continue
        nodes.append({
            "name": hostname,
            "addr": address,
            "cpus": cpus,
            "real_memory": max(memory - mem_reserve_mib, 1),
            "gpus": gpus,
            "device": device["name"],
        })

    # Cabling. A link_peer on a node's interface names the switch it plugs
    # into; a link_peer on a switch's interface names its neighbour.
    node_by_device = {n["device"]: n["name"] for n in nodes}
    switch_names = {d["id"]: d["name"] for d in devices if role_of[d["id"]] == switch_role}
    leaf_nodes = {}       # switch name -> {node hostnames}
    switch_links = {}     # switch name -> {neighbour switch names}
    for iface in interfaces:
        owner = (iface.get("device") or {}).get("id")
        peers = [((p.get("device") or {}).get("id")) for p in (iface.get("link_peers") or [])]
        for peer in peers:
            if owner in switch_names and peer in switch_names:
                switch_links.setdefault(switch_names[owner], set()).add(switch_names[peer])
            elif peer in switch_names and owner in by_id and by_id[owner]["name"] in node_by_device:
                leaf_nodes.setdefault(switch_names[peer], set()).add(node_by_device[by_id[owner]["name"]])

    uncabled = sorted(set(node_by_device.values()) - set().union(*leaf_nodes.values()))
    if uncabled:
        problems.append(f"not cabled to any switch: {', '.join(uncabled)}")
    if problems:
        raise ModelError("; ".join(problems))

    # Two tiers: a switch with nodes is a leaf; a switch cabled to leaves is
    # their parent. Only switches that lead to an active node are emitted.
    leaves = sorted(leaf_nodes)
    switches = [{"name": leaf, "nodes": sorted(leaf_nodes[leaf]), "switches": []} for leaf in leaves]
    parents = {}
    for leaf in leaves:
        for neighbour in switch_links.get(leaf, set()):
            if neighbour not in leaf_nodes:
                parents.setdefault(neighbour, set()).add(leaf)
    switches += [{"name": spine, "nodes": [], "switches": sorted(children)}
                 for spine, children in sorted(parents.items())]

    return {"nodes": sorted(nodes, key=lambda n: n["name"]), "switches": switches,
            "gres": any(n["gpus"] for n in nodes)}


def _get_all(base, token, path):
    req = urllib.request.Request(f"{base}{path}{'&' if '?' in path else '?'}limit=0",
                                 headers={"Authorization": f"Token {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)["results"]


def main():
    base = os.environ.get("NETBOX_URL", "http://127.0.0.1:8000").rstrip("/")
    token = os.environ["NETBOX_TOKEN"]
    compute = os.environ.get("SLURM_COMPUTE_ROLE", "compute")
    switch = os.environ.get("SLURM_SWITCH_ROLE", "switch")
    devices = (_get_all(base, token, f"/api/dcim/devices/?role={compute}")
               + _get_all(base, token, f"/api/dcim/devices/?role={switch}"))
    addresses = _get_all(base, token, "/api/ipam/ip-addresses/?assigned_to_interface=true")
    interfaces = _get_all(base, token, "/api/dcim/interfaces/?cabled=true")
    try:
        model = build_model(devices, addresses, interfaces, compute_role=compute, switch_role=switch,
                            mem_reserve_mib=int(os.environ.get("SLURM_MEM_RESERVE_MIB", "0")))
    except ModelError as exc:
        print(f"render-slurm-model: NetBox is incomplete: {exc}", file=sys.stderr)
        return 2
    json.dump(model, sys.stdout, sort_keys=True)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
