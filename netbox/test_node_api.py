#!/usr/bin/env python3
"""Unit tests for cluster-node-api: identity, facts shape, write validation.

The role file is loaded by path, like the dnsmasq renderer, because it is
deployed as /usr/local/sbin/cluster-node-api rather than as a package. All
addresses and MACs below are lab-internal or synthetic.
"""

from __future__ import annotations

import importlib.util
import os
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROLE_FILE = HERE.parent / "ansible" / "roles" / "node_api" / "files" / "cluster_node_api.py"
_spec = importlib.util.spec_from_file_location("cluster_node_api", ROLE_FILE)
api = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(api)

SETTINGS = {"role_slug": "compute", "controller_address": "10.42.0.1",
            "slurmctld_port": 6817, "node_exporter_port": 9100}


class FakeNetBox:
    """Just enough of NetBox for one compute node and one switch."""

    def __init__(self):
        self.patches = []
        self.devices = {
            1: {"id": 1, "name": "rack-a-u01", "status": {"value": "active"},
                "role": {"slug": "compute"}, "site": {"name": "lab"},
                "rack": {"name": "rack-a"}, "position": 1.0,
                "custom_fields": {"discovered_cpu_count": "2",
                                  "discovered_memory_mib": "1967",
                                  "last_converged_at": "2026-10-12T10:00:00Z",
                                  "convergence_result": "success",
                                  "convergence_duration_seconds": "12.5",
                                  "last_git_sha": "abc1234", "image_tag": "sha-1"}},
            9: {"id": 9, "name": "leaf-rack-a", "status": {"value": "active"},
                "role": {"slug": "switch"}, "custom_fields": {}},
        }
        self.ips = [
            {"address": "10.42.0.20/24", "dns_name": "cn01.lab.internal",
             "assigned_object_type": "dcim.interface", "assigned_object_id": 11,
             "assigned_object": {"id": 11, "device": {"id": 1}}},
            {"address": "10.42.0.250/24", "dns_name": "",
             "assigned_object_type": "dcim.interface", "assigned_object_id": 90,
             "assigned_object": {"id": 90, "device": {"id": 9}}},
        ]

    def get(self, path):
        device_id = int(path.rstrip("/").rsplit("/", 1)[1])
        return self.devices[device_id]

    def list(self, path):
        if path.startswith("/api/ipam/ip-addresses/?address="):
            wanted = path.split("=", 1)[1]
            return [ip for ip in self.ips if ip["address"].split("/")[0] == wanted]
        if path.startswith("/api/ipam/ip-addresses/?device_id=1"):
            return [self.ips[0]]
        if path.startswith("/api/ipam/ip-addresses/"):
            return self.ips
        if path.startswith("/api/dcim/interfaces/?device_id=1"):
            return [{"id": 11, "name": "provisioning",
                     "primary_mac_address": {"mac_address": "52:54:00:00:00:01"}}]
        if path.startswith("/api/dcim/devices/?role=compute"):
            return [self.devices[1]]
        raise AssertionError(path)

    def patch(self, path, body):
        self.patches.append((path, body))


class IdentityTest(unittest.TestCase):
    def test_source_address_resolves_to_its_device(self):
        device, ip = api.device_for_address(FakeNetBox(), "10.42.0.20", "compute")
        self.assertEqual(device["name"], "rack-a-u01")
        self.assertEqual(ip["dns_name"], "cn01.lab.internal")

    def test_an_unknown_address_is_not_a_node(self):
        with self.assertRaises(api.NotANode):
            api.device_for_address(FakeNetBox(), "10.42.0.99", "compute")

    def test_a_switch_address_is_not_a_node(self):
        with self.assertRaises(api.NotANode):
            api.device_for_address(FakeNetBox(), "10.42.0.250", "compute")

    def test_garbage_is_rejected_before_netbox_is_asked(self):
        with self.assertRaises(ValueError):
            api.device_for_address(FakeNetBox(), "not-an-ip", "compute")


class FactsTest(unittest.TestCase):
    def setUp(self):
        self.facts = api.node_facts(FakeNetBox(), "10.42.0.20", SETTINGS)

    def test_hostname_comes_from_the_dns_name(self):
        self.assertEqual(self.facts["hostname"], "cn01")
        self.assertEqual(self.facts["device"]["name"], "rack-a-u01")

    def test_status_is_the_plain_value(self):
        self.assertEqual(self.facts["device"]["status"], "active")

    def test_no_volatile_field_reaches_the_cached_facts(self):
        text = repr(self.facts)
        for volatile in ("last_converged_at", "convergence", "abc1234", "sha-1"):
            self.assertNotIn(volatile, text)

    def test_inventory_is_numeric(self):
        self.assertEqual(self.facts["inventory"], {"cpu_count": 2, "memory_mib": 1967, "gpu_count": None})

    def test_interfaces_carry_mac_and_addresses(self):
        self.assertEqual(self.facts["interfaces"], [
            {"name": "provisioning", "mac": "52:54:00:00:00:01", "addresses": ["10.42.0.20/24"]}])


GOOD_RUN = {"result": "success", "git_sha": "0123456789abcdef0123456789abcdef01234567",
            "image_tag": "sha-1bb6b9f6f98e", "duration_seconds": 41.2,
            "finished_at": "2026-10-12T10:00:00Z", "run_id": "boot-1", "failed_task": ""}


class ConvergenceValidationTest(unittest.TestCase):
    def test_a_good_report_maps_to_exactly_the_whitelisted_fields(self):
        fields = api.validate_convergence(dict(GOOD_RUN))
        self.assertEqual(set(fields), set(api.CONVERGENCE_FIELDS))
        self.assertEqual(fields["convergence_duration_seconds"], "41.200")

    def test_status_cannot_be_smuggled_in(self):
        fields = api.validate_convergence({**GOOD_RUN, "status": "active"})
        self.assertNotIn("status", fields)

    def test_bad_values_are_refused(self):
        for key, value in (("result", "ok"), ("git_sha", "main"), ("duration_seconds", "x"),
                           ("finished_at", "yesterday"), ("run_id", "a b")):
            with self.subTest(key=key), self.assertRaises(api.BadRequest):
                api.validate_convergence({**GOOD_RUN, key: value})


class BurninValidationTest(unittest.TestCase):
    BODY = {"reported_at": "2026-10-12T10:00:00Z", "image_tag": "sha-1",
            "checks": {"cpu": {"bogo_ops_per_second": 812.5, "exit_code": 0, "passed": True},
                       "memory": {"exit_code": 0, "bytes": 1000},
                       "disk": {"write_mib_per_second": 120.0, "exit_code": 0}}}

    def test_a_node_supplied_verdict_is_dropped(self):
        fields = api.validate_burnin(self.BODY)
        self.assertNotIn("passed", fields["burnin_results"]["checks"]["cpu"])
        self.assertEqual(fields["burnin_results"]["checks"]["cpu"]["bogo_ops_per_second"], 812.5)

    def test_templated_numbers_are_stored_as_numbers(self):
        body = {**self.BODY, "checks": {"cpu": {"bogo_ops_per_second": "812.5", "exit_code": "0"},
                                        "memory": {"exit_code": "-1"},
                                        "disk": {"device": "vda", "write_mib_per_second": "0.0"}}}
        checks = api.validate_burnin(body)["burnin_results"]["checks"]
        self.assertEqual(checks["cpu"], {"bogo_ops_per_second": 812.5, "exit_code": 0})
        self.assertEqual(checks["memory"]["exit_code"], -1)
        self.assertEqual(checks["disk"], {"device": "vda", "write_mib_per_second": 0.0})

    def test_every_check_must_be_present(self):
        body = {**self.BODY, "checks": {"cpu": {}}}
        with self.assertRaises(api.BadRequest):
            api.validate_burnin(body)


class ObservabilityTest(unittest.TestCase):
    def test_metrics_carry_the_last_convergence(self):
        text = api.render_metrics(api.fleet(FakeNetBox(), "compute"))
        self.assertIn('cluster_node_convergence_success{device="rack-a-u01",hostname="cn01"} 1', text)
        self.assertIn("cluster_node_last_converged_timestamp_seconds{", text)
        self.assertIn('git_sha="abc1234"', text)

    def test_timestamps_are_utc_whatever_the_local_zone(self):
        saved = os.environ.get("TZ")
        try:
            for zone in ("UTC", "America/Chicago", "Australia/Sydney"):
                os.environ["TZ"] = zone
                time.tzset()
                self.assertEqual(api._epoch("2026-10-12T20:26:00Z"), 1791836760.0)
                self.assertEqual(api._epoch("2026-01-12T20:26:00Z"), 1768249560.0)
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            time.tzset()

    def test_devices_that_do_not_run_pulls_are_not_exported(self):
        rows = [({"name": "rack-a-u03", "status": {"value": "planned"}, "custom_fields": {}}, None, None)]
        self.assertNotIn("rack-a-u03", api.render_metrics(rows))

    def test_sd_targets_come_from_netbox(self):
        sd = api.render_sd(api.fleet(FakeNetBox(), "compute"), 9100)
        self.assertEqual(sd, [{"targets": ["10.42.0.20:9100"],
                               "labels": {"hostname": "cn01", "device": "rack-a-u01"}}])


if __name__ == "__main__":
    unittest.main()
