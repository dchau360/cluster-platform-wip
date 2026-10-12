#!/usr/bin/env python3
"""Unit tests for the Slurm model renderer: NetBox objects in, model out.

N is a parameter of the fixture, not a constant, so the same assertions run
for N=2 and N=4.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROLE_FILE = HERE.parent / "ansible" / "roles" / "slurm_config" / "files" / "render_slurm.py"
_spec = importlib.util.spec_from_file_location("render_slurm", ROLE_FILE)
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)


def fabric(n, statuses=None, cpus="2", memory="1967", uncabled=()):
    """N compute devices on one leaf, the leaf on one spine."""
    statuses = statuses or {}
    devices, addresses, interfaces = [], [], []
    leaf_id, spine_id = 900, 901
    devices.append({"id": leaf_id, "name": "leaf-rack-a", "role": {"slug": "switch"}, "status": {"value": "active"}})
    devices.append({"id": spine_id, "name": "spine-01", "role": {"slug": "switch"}, "status": {"value": "active"}})
    for i in range(1, n + 1):
        devices.append({"id": i, "name": f"rack-a-u{i:02d}", "role": {"slug": "compute"},
                        "status": {"value": statuses.get(i, "active")},
                        "custom_fields": {"discovered_cpu_count": cpus, "discovered_memory_mib": memory,
                                          "discovered_gpu_count": "0"}})
        addresses.append({"address": f"10.42.0.{19 + i}/24", "dns_name": f"cn{i:02d}.lab.internal",
                          "assigned_object": {"device": {"id": i}}})
        if i not in uncabled:
            interfaces.append({"device": {"id": i}, "link_peers": [{"device": {"id": leaf_id}}]})
    interfaces.append({"device": {"id": leaf_id}, "link_peers": [{"device": {"id": spine_id}}]})
    interfaces.append({"device": {"id": spine_id}, "link_peers": [{"device": {"id": leaf_id}}]})
    return devices, addresses, interfaces


class ModelTest(unittest.TestCase):
    def test_every_active_node_for_any_n(self):
        for n in (2, 4):
            with self.subTest(n=n):
                model = render.build_model(*fabric(n), mem_reserve_mib=256)
                self.assertEqual([x["name"] for x in model["nodes"]], [f"cn{i:02d}" for i in range(1, n + 1)])
                self.assertEqual(model["nodes"][0]["real_memory"], 1967 - 256)
                self.assertEqual(model["switches"], [
                    {"name": "leaf-rack-a", "nodes": [f"cn{i:02d}" for i in range(1, n + 1)], "switches": []},
                    {"name": "spine-01", "nodes": [], "switches": ["leaf-rack-a"]},
                ])

    def test_a_staged_node_is_not_a_slurm_node(self):
        model = render.build_model(*fabric(2, statuses={2: "staged"}))
        self.assertEqual([x["name"] for x in model["nodes"]], ["cn01"])
        self.assertEqual(model["switches"][0]["nodes"], ["cn01"])

    def test_missing_discovery_data_is_an_error_not_a_default(self):
        with self.assertRaisesRegex(render.ModelError, "discovered_cpu_count"):
            render.build_model(*fabric(2, cpus=None))

    def test_an_uncabled_node_is_an_error(self):
        with self.assertRaisesRegex(render.ModelError, "not cabled.*cn02"):
            render.build_model(*fabric(2, uncabled=(2,)))

    def test_no_gres_without_gpus(self):
        self.assertFalse(render.build_model(*fabric(2))["gres"])


if __name__ == "__main__":
    unittest.main()
