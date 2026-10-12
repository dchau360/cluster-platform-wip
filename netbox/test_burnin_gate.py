#!/usr/bin/env python3
"""Unit tests for the burn-in gate's judgement."""

from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "ansible" / "playbooks" / "day2" / "files" / "burnin_gate.py"
_spec = importlib.util.spec_from_file_location("burnin_gate", GATE)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

THRESHOLDS = {"cpu_bogo_ops_per_worker": 20.0, "disk_write_mib_per_second": 20.0,
              "disk_read_mib_per_second": 20.0}

GOOD = {"schema": 1, "image_tag": "sha-1", "reported_at": "2026-10-12T10:00:00Z", "checks": {
    "cpu": {"exit_code": 0, "workers": 2, "bogo_ops_per_second": 400.0},
    "memory": {"exit_code": 0, "bogo_ops_per_second": 1000.0},
    "disk": {"device": "vda", "exit_code": 0, "job_error": 0,
             "write_mib_per_second": 300.0, "verify_read_mib_per_second": 500.0}}}


def with_(path, value):
    results = copy.deepcopy(GOOD)
    check, key = path.split(".")
    results["checks"][check][key] = value
    return results


class GateTest(unittest.TestCase):
    def test_a_healthy_node_passes(self):
        self.assertEqual(gate.evaluate(GOOD, THRESHOLDS, "sha-1"), (True, []))

    def test_a_throttled_disk_is_held_back(self):
        passed, reasons = gate.evaluate(with_("disk.write_mib_per_second", 1.0), THRESHOLDS, "sha-1")
        self.assertFalse(passed)
        self.assertIn("disk write_mib_per_second 1.0 < 20.0", reasons)

    def test_a_verify_failure_is_held_back_whatever_the_speed(self):
        passed, reasons = gate.evaluate(with_("memory.exit_code", 2), THRESHOLDS, "sha-1")
        self.assertFalse(passed)
        self.assertIn("memory exited 2", reasons)

    def test_missing_data_fails_rather_than_passing(self):
        results = copy.deepcopy(GOOD)
        del results["checks"]["disk"]["write_mib_per_second"]
        self.assertFalse(gate.evaluate(results, THRESHOLDS, "sha-1")[0])
        self.assertFalse(gate.evaluate({}, THRESHOLDS)[0])

    def test_no_disk_is_a_failure(self):
        self.assertFalse(gate.evaluate(with_("disk.device", ""), THRESHOLDS, "sha-1")[0])

    def test_results_from_another_image_do_not_count(self):
        passed, reasons = gate.evaluate(GOOD, THRESHOLDS, "sha-2")
        self.assertFalse(passed)
        self.assertTrue(any("node runs sha-2" in r for r in reasons))

    def test_a_node_supplied_verdict_is_ignored(self):
        results = with_("disk.write_mib_per_second", 1.0)
        results["checks"]["disk"]["passed"] = True
        results["passed"] = True
        self.assertFalse(gate.evaluate(results, THRESHOLDS, "sha-1")[0])


if __name__ == "__main__":
    unittest.main()
