#!/usr/bin/env python3
"""The burn-in acceptance gate. Runs on the head node, never on the node.

For every `staged` compute device with burn-in results, recompute pass/fail
from the raw measurements against thresholds this repository holds, and set
the device status:

    every check passes  -> active   (slurm_config then adds it to Slurm)
    any check fails     -> failed   (held back; the reasons are recorded)
    no results yet      -> unchanged, still staged

The node only ever wrote numbers through the node API, which drops any
verdict it sends. Status is written here and nowhere else. A node cannot
promote itself, because nothing it can reach can write its status.

Standard library only. Prints a JSON summary; exit 0 unless NetBox fails.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from datetime import datetime, timezone


def evaluate(results, thresholds, current_image_tag=None):
    """(passed, reasons). Pure. Missing data fails, it is never assumed."""
    reasons = []
    if not isinstance(results, dict) or not isinstance(results.get("checks"), dict):
        return False, ["no structured burn-in results"]
    checks = results["checks"]

    def number(check, key):
        value = (checks.get(check) or {}).get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            reasons.append(f"{check}.{key} missing")
            return None
        return value

    for check in ("cpu", "memory", "disk"):
        code = number(check, "exit_code")
        if code is not None and code != 0:
            reasons.append(f"{check} exited {code}")

    ops = number("cpu", "bogo_ops_per_second")
    workers = number("cpu", "workers")
    if ops is not None and workers:
        per_worker = ops / workers
        if per_worker < thresholds["cpu_bogo_ops_per_worker"]:
            reasons.append(f"cpu {per_worker:.1f} bogo-ops/s per worker < {thresholds['cpu_bogo_ops_per_worker']}")

    mem_ops = number("memory", "bogo_ops_per_second")
    if mem_ops is not None and mem_ops <= 0:
        reasons.append("memory stressor did no work")

    if not (checks.get("disk") or {}).get("device"):
        reasons.append("no scratch disk was tested")
    job_error = number("disk", "job_error")
    if job_error is not None and job_error != 0:
        reasons.append(f"disk fio error {job_error}")
    for key, floor in (("write_mib_per_second", thresholds["disk_write_mib_per_second"]),
                       ("verify_read_mib_per_second", thresholds["disk_read_mib_per_second"])):
        value = number("disk", key)
        if value is not None and value < floor:
            reasons.append(f"disk {key} {value} < {floor}")

    if current_image_tag and results.get("image_tag") not in (current_image_tag,):
        reasons.append(f"results are for image {results.get('image_tag')}, node runs {current_image_tag}")

    return not reasons, reasons


class NetBox:
    def __init__(self, url, token):
        self.url, self.token = url.rstrip("/"), token

    def _req(self, method, path, body=None):
        req = urllib.request.Request(
            self.url + path, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Token {self.token}", "Accept": "application/json",
                     "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    def staged(self, role):
        return self._req("GET", f"/api/dcim/devices/?role={role}&status=staged&limit=0")["results"]

    def patch(self, device_id, body):
        return self._req("PATCH", f"/api/dcim/devices/{device_id}/", body)


def main():
    thresholds = {
        "cpu_bogo_ops_per_worker": float(os.environ["BURNIN_MIN_CPU_BOGO_OPS_PER_WORKER"]),
        "disk_write_mib_per_second": float(os.environ["BURNIN_MIN_DISK_WRITE_MIB_S"]),
        "disk_read_mib_per_second": float(os.environ["BURNIN_MIN_DISK_READ_MIB_S"]),
    }
    nb = NetBox(os.environ.get("NETBOX_URL", "http://127.0.0.1:8000"), os.environ["NETBOX_TOKEN"])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    summary = {"promoted": [], "failed": [], "waiting": []}
    for device in nb.staged(os.environ.get("BURNIN_ROLE", "compute")):
        custom = device.get("custom_fields") or {}
        results = custom.get("burnin_results")
        if not results:
            summary["waiting"].append(device["name"])
            continue
        passed, reasons = evaluate(results, thresholds, custom.get("image_tag"))
        verdict = (f"pass {now}" if passed else f"fail {now}: " + "; ".join(reasons))[:500]
        nb.patch(device["id"], {"status": "active" if passed else "failed",
                                "custom_fields": {"burnin_verdict": verdict}})
        summary["promoted" if passed else "failed"].append({"device": device["name"], "verdict": verdict})
    json.dump(summary, sys.stdout, sort_keys=True)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
