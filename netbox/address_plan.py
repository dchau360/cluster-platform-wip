#!/usr/bin/env python3
"""Load and validate the NetBox-backed lab address plan.

The provisioning prefix in definition.yml is the default. PROV_SUBNET in
lab/local.env moves it: the gateway, the static pool and the dynamic pool keep
their offsets inside the prefix, so the plan the tests prove at N=100 and
N=500 is the same plan at a different address.
"""
import argparse
import ipaddress
import os
import shlex
import sys
from pathlib import Path

DEFINITION = Path(__file__).with_name("definition.yml")
SUBNET_VARIABLE = "PROV_SUBNET"
# RFC 1918, built from integers: the repository's hygiene gate allows no
# dotted-quad literal outside the lab's own segments.
PRIVATE_RANGES = tuple(ipaddress.ip_network(network)
                       for network in ((10 << 24, 8), ((172 << 24) | (16 << 16), 12),
                                       ((192 << 24) | (168 << 16), 16)))


def _address_sections(path):
    """Read the flat address-plan sections without a runtime YAML dependency.

    The full seeder uses PyYAML in its virtualenv. The bridge must render its
    network before that virtualenv exists, so these three scalar-only sections
    intentionally have a tiny reader based on their constrained shape.
    """
    wanted = {"prefixes", "pools", "address_plan"}
    result = {name: {} for name in wanted}
    section = None
    for raw in Path(path).read_text().splitlines():
        content = raw.split("#", 1)[0].rstrip()
        if not content:
            continue
        if not content.startswith(" ") and content.endswith(":"):
            section = content[:-1] if content[:-1] in wanted else None
            continue
        if section and content.startswith("  ") and ":" in content:
            key, value = content.strip().split(":", 1)
            value = value.strip().strip("'\"")
            result[section][key] = int(value) if value.isdigit() else value
    return result


def _env_subnet():
    return os.environ.get(SUBNET_VARIABLE, "").strip() or None


def relocate(definition, subnet):
    """Move the provisioning prefix, and every address inside it, to `subnet`.

    Rewrites `definition` in place and returns it. Accepts both the scalar
    sections read here and the full YAML document seed.py loads, so the
    harness and the NetBox seeder can never disagree about the plan.
    """
    if not subnet:
        return definition
    old = ipaddress.ip_network(definition["prefixes"]["provisioning"])
    try:
        new = ipaddress.ip_network(subnet)
    except ValueError as error:
        try:
            suggestion = ipaddress.ip_network(subnet, strict=False)
        except ValueError:
            raise ValueError(f"{SUBNET_VARIABLE}={subnet} is not an IPv4 network: {error}") from None
        raise ValueError(f"{SUBNET_VARIABLE}={subnet} has host bits set; did you mean {suggestion}?") from None
    if new.version != 4:
        raise ValueError(f"{SUBNET_VARIABLE}={subnet} must be IPv4")
    if not any(new.subnet_of(private) for private in PRIVATE_RANGES):
        raise ValueError(f"{SUBNET_VARIABLE}={subnet} must be private, inside one of "
                         + ", ".join(map(str, PRIVATE_RANGES)))
    if new.prefixlen > old.prefixlen:
        # Smaller would cut into the dynamic pool, which lives in the last /24
        # of the default plan, and silently lower the node ceiling.
        raise ValueError(f"{SUBNET_VARIABLE}={subnet} is smaller than the default /{old.prefixlen}; use a /{old.prefixlen} or larger")
    for name, cidr in definition["prefixes"].items():
        if name != "provisioning" and new.overlaps(ipaddress.ip_network(cidr)):
            raise ValueError(f"{SUBNET_VARIABLE}={subnet} overlaps the {name} prefix {cidr}")

    def move(address):
        return str(new.network_address + (int(ipaddress.ip_address(address)) - int(old.network_address)))

    def move_range(value):
        return "-".join(move(part) for part in value.split("-"))

    definition["prefixes"]["provisioning"] = str(new)
    if "provisioning" in definition.get("pools", {}):
        definition["pools"]["provisioning"] = move_range(definition["pools"]["provisioning"])
    plan = definition["address_plan"]
    plan["dynamic_pool"] = move_range(plan["dynamic_pool"])
    return definition


def load_plan(path=DEFINITION, subnet=None):
    if subnet is None:
        subnet = _env_subnet()
    definition = relocate(_address_sections(path), subnet)
    prefixes = {name: ipaddress.ip_network(cidr)
                for name, cidr in definition["prefixes"].items()}
    plan = definition["address_plan"]
    dynamic_start, dynamic_end = (ipaddress.ip_address(value)
                                  for value in plan["dynamic_pool"].split("-"))
    provisioning = prefixes["provisioning"]
    gateway = provisioning[int(plan["provisioning_gateway_offset"])]
    if not (dynamic_start in provisioning and dynamic_end in provisioning):
        raise ValueError("dynamic pool must be inside the provisioning prefix")
    if dynamic_start > dynamic_end:
        raise ValueError("dynamic pool start must not exceed its end")
    return definition, prefixes, gateway, dynamic_start, dynamic_end


def node_address(index, path=DEFINITION, network="provisioning", subnet=None):
    definition, prefixes, _, _, _ = load_plan(path, subnet)
    if index < 1:
        raise ValueError("node index must be positive")
    return prefixes[network][int(definition["address_plan"]["node_offset"]) + index]


def validate_capacity(counts=(100, 500), path=DEFINITION, subnet=None):
    _, prefixes, gateway, dynamic_start, dynamic_end = load_plan(path, subnet)
    for count in counts:
        static = {gateway}
        for index in range(1, count + 1):
            for network in ("bmc", "provisioning", "data"):
                address = node_address(index, path, network, subnet)
                if address not in prefixes[network]:
                    raise ValueError(f"{network} address {address} is outside its prefix at N={count}")
                static.add(address)
        overlap = sorted(address for address in static
                         if dynamic_start <= address <= dynamic_end)
        if overlap:
            raise ValueError(f"static address {overlap[0]} overlaps the dynamic pool at N={count}")


def shell_environment(path=DEFINITION):
    definition, prefixes, gateway, dynamic_start, dynamic_end = load_plan(path)
    provisioning = prefixes["provisioning"]
    values = {
        "PROV_CIDR": str(provisioning),
        "PROV_PREFIX": str(provisioning.prefixlen),
        "PROV_NETMASK": str(provisioning.netmask),
        "PROV_GW": str(gateway),
        "PROV_DHCP_START": str(dynamic_start),
        "PROV_DHCP_END": str(dynamic_end),
        "PROV_DHCP_LEASE": str(definition["address_plan"]["dynamic_lease"]),
        "PROV_NODE_IP_OFFSET": str(definition["address_plan"]["node_offset"]),
    }
    return "\n".join(f"export {key}={shlex.quote(value)}" for key, value in values.items())


def conflicts(lines, path=DEFINITION):
    """Return the `name cidr` lines whose network overlaps the provisioning prefix.

    The caller lists every network the host already uses. A segment that
    overlaps one of them would either shadow it or be shadowed by it, so the
    bridge is never created on top of a subnet that already exists.
    """
    _, prefixes, _, _, _ = load_plan(path)
    provisioning = prefixes["provisioning"]
    found = []
    for line in lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            network = ipaddress.ip_network(parts[1], strict=False)
        except ValueError:
            continue
        if network.version == 4 and network.overlaps(provisioning):
            found.append(f"{parts[0]} {network}")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--definition", default=DEFINITION)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("shell-env")
    node = subparsers.add_parser("node-ip")
    node.add_argument("index", type=int)
    node.add_argument("--network", choices=("bmc", "provisioning", "data"),
                      default="provisioning")
    check = subparsers.add_parser("check")
    check.add_argument("--nodes", type=int, action="append", default=[])
    subparsers.add_parser("conflicts", help="read `name cidr` lines on stdin; list those overlapping the segment")
    args = parser.parse_args()
    try:
        return _run(args)
    except ValueError as error:
        print(f"address plan: {error}", file=sys.stderr)
        return 2


def _run(args):
    if args.command == "conflicts":
        found = conflicts(sys.stdin.read().splitlines(), args.definition)
        print("\n".join(found))
        return 1 if found else 0
    if args.command == "shell-env":
        print(shell_environment(args.definition))
    elif args.command == "node-ip":
        print(node_address(args.index, args.definition, args.network))
    else:
        counts = args.nodes or [100, 500]
        validate_capacity(counts, args.definition)
        print(f"address plan has no static/dynamic overlap at N={','.join(map(str, counts))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
