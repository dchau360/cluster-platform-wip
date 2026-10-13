#!/usr/bin/env python3
"""Load and validate the NetBox-backed lab address plan."""
import argparse
import ipaddress
import shlex
from pathlib import Path

DEFINITION = Path(__file__).with_name("definition.yml")


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


def load_plan(path=DEFINITION):
    definition = _address_sections(path)
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


def node_address(index, path=DEFINITION, network="provisioning"):
    definition, prefixes, _, _, _ = load_plan(path)
    if index < 1:
        raise ValueError("node index must be positive")
    return prefixes[network][int(definition["address_plan"]["node_offset"]) + index]


def validate_capacity(counts=(100, 500), path=DEFINITION):
    _, prefixes, gateway, dynamic_start, dynamic_end = load_plan(path)
    for count in counts:
        static = {gateway}
        for index in range(1, count + 1):
            for network in ("bmc", "provisioning", "data"):
                address = node_address(index, path, network)
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
    args = parser.parse_args()
    if args.command == "shell-env":
        print(shell_environment(args.definition))
    elif args.command == "node-ip":
        print(node_address(args.index, args.definition, args.network))
    else:
        counts = args.nodes or [100, 500]
        validate_capacity(counts, args.definition)
        print(f"address plan has no static/dynamic overlap at N={','.join(map(str, counts))}")


if __name__ == "__main__":
    main()
