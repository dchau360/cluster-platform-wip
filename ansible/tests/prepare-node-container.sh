#!/bin/bash
#
# Turn a running compute-node image container into a stand-in for a booted
# node, for CI: the pieces Warewulf and the head node would have supplied.
#
#   - a throwaway Munge key, generated here, never committed;
#   - the image reference the overlay would deliver;
#   - a facts document in exactly the shape the node API serves, built from
#     the container's own address and MAC so network_from_netbox's drift
#     check sees what it would see on a node.
#
# Runs inside the container. Prints the facts file path.

set -euo pipefail

STATUS="${NODE_STATUS:-active}"
install -d -m 0755 /etc/cluster-lab /var/cache/cluster-node
if [[ ! -s /etc/cluster-lab/munge.key ]]; then
  dd if=/dev/urandom of=/etc/cluster-lab/munge.key bs=1 count=1024 status=none
  chmod 0400 /etc/cluster-lab/munge.key
fi
echo "docker://ci.invalid/compute-slurm:ci" > /etc/cluster-lab/image-reference

iface="$(ip -o -4 route show default | awk '{print $5; exit}')"
iface="${iface:-eth0}"
addr="$(ip -o -4 addr show dev "$iface" | awk '{print $4; exit}')"
mac="$(cat "/sys/class/net/$iface/address")"

python3 - "$addr" "$mac" "$STATUS" "$(hostname)" <<'PY'
import json, sys
addr, mac, status, hostname = sys.argv[1:]
facts = {
    "schema": 1,
    "device": {"id": 1, "name": "rack-a-u01", "status": status, "site": "lab",
               "rack": "rack-a", "position": 1.0},
    "hostname": hostname,
    "address": addr,
    "interfaces": [{"name": "provisioning", "mac": mac.lower(), "addresses": [addr]}],
    "inventory": {"cpu_count": 2, "memory_mib": 2048, "gpu_count": None},
    "controller": {"address": "10.42.0.1", "slurmctld_port": 6817},
}
with open("/etc/cluster-lab/node-facts.json", "w") as fh:
    json.dump(facts, fh, indent=2)
PY
echo /etc/cluster-lab/node-facts.json
