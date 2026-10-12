#!/usr/bin/env python3
"""cluster-node-api: a node's only door to NetBox.

A compute node configures itself (ansible-pull) and must hold no credential of
its own. It still has to read its NetBox record and write back what it did.
This service, on the head node, holds the one NetBox token and offers a node
exactly three things, about itself only:

    GET  /v1/self               the node's facts, shaped for local.yml
    POST /v1/self/convergence   the result of one pull run
    POST /v1/self/burnin        raw burn-in measurements (never a verdict)

"Self" is the client's source address. The service listens on the
provisioning segment only; that segment has no uplink and every node address
is a NetBox reservation, so the source address is the node's identity. That is
an isolation argument, not a cryptographic one, and docs/node-self-configuration.md
says so.

A node can never change its own status, its name or anything outside the
custom fields listed below. The burn-in gate, which does change the status,
runs on the head node and reads NetBox directly.

Two read-only endpoints serve the head node's Prometheus:

    GET  /metrics               last convergence per node, for the stale alert
    GET  /v1/sd/node-exporter   http_sd targets, from NetBox, not a list

Standard library only, so the head node needs no extra package.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FACTS_SCHEMA = 1
MAX_BODY = 64 * 1024

# Custom fields a node may write, and nothing else.
CONVERGENCE_FIELDS = (
    "last_git_sha", "image_tag", "convergence_result",
    "convergence_duration_seconds", "last_converged_at",
    "convergence_run_id", "convergence_failed_task",
)

_SHA = re.compile(r"^(?:[0-9a-f]{7,40}|unknown)$")
_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,255}$")
_RUN = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_STAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
_TASK = re.compile(r"^[\x20-\x7e]{0,200}$")


class BadRequest(ValueError):
    """The body is not something a node is allowed to send."""


class NotANode(LookupError):
    """The caller's address does not belong to a compute node."""


# ---------------------------------------------------------------------------
# NetBox access. Injected, so the shaping below is testable without a server.
# ---------------------------------------------------------------------------

class NetBox:
    def __init__(self, url: str, token: str, timeout: float = 10.0):
        self.url = url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def _request(self, method: str, path: str, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            self.url + path, data=data, method=method,
            headers={"Authorization": f"Token {self.token}",
                     "Accept": "application/json",
                     "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.load(resp)

    def get(self, path: str):
        return self._request("GET", path)

    def list(self, path: str):
        sep = "&" if "?" in path else "?"
        return self.get(f"{path}{sep}limit=0")["results"]

    def patch(self, path: str, body):
        return self._request("PATCH", path, body)


# ---------------------------------------------------------------------------
# Identity: source address -> device.
# ---------------------------------------------------------------------------

def device_for_address(nb, address: str, role_slug: str):
    """The compute device whose interface holds `address`, or NotANode."""
    ipaddress.ip_address(address)  # raises ValueError on garbage
    for ip in nb.list(f"/api/ipam/ip-addresses/?address={address}"):
        if ip.get("assigned_object_type") != "dcim.interface":
            continue
        assigned = ip.get("assigned_object") or {}
        device_ref = assigned.get("device") or {}
        if "id" not in device_ref:
            continue
        device = nb.get(f"/api/dcim/devices/{device_ref['id']}/")
        if (device.get("role") or {}).get("slug") != role_slug:
            raise NotANode(f"{address} belongs to a non-compute device")
        return device, ip
    raise NotANode(f"no compute device holds {address}")


def _short(dns_name: str | None) -> str | None:
    dns_name = (dns_name or "").strip()
    return dns_name.split(".")[0] if dns_name else None


def _value(field):
    """NetBox renders choice fields as {"value": ...}; plain fields as is."""
    if isinstance(field, dict) and "value" in field:
        return field["value"]
    return field


def _mac(interface) -> str | None:
    primary = interface.get("primary_mac_address") or {}
    mac = primary.get("mac_address") or interface.get("mac_address")
    return mac.lower() if mac else None


def shape_facts(device, address_obj, interfaces, addresses, settings):
    """The document a node's local.yml runs from.

    Deliberately free of anything that changes when the node merely runs:
    no convergence fields, no timestamps. The node caches this file, and a
    cache that changes every run would make every run report a change.
    """
    custom = device.get("custom_fields") or {}
    by_interface = {}
    for addr in addresses:
        if addr.get("assigned_object_type") != "dcim.interface":
            continue
        by_interface.setdefault(addr["assigned_object_id"], []).append(addr["address"])
    rack = device.get("rack") or {}
    site = device.get("site") or {}
    return {
        "schema": FACTS_SCHEMA,
        "device": {
            "id": device["id"],
            "name": device["name"],
            "status": _value(device.get("status")),
            "site": site.get("name"),
            "rack": rack.get("name"),
            "position": device.get("position"),
        },
        "hostname": _short(address_obj.get("dns_name")),
        "address": address_obj["address"],
        "interfaces": sorted((
            {
                "name": iface["name"],
                "mac": _mac(iface),
                "addresses": sorted(by_interface.get(iface["id"], [])),
            }
            for iface in interfaces
        ), key=lambda i: i["name"]),
        "inventory": {
            "cpu_count": _int_or_none(custom.get("discovered_cpu_count")),
            "memory_mib": _int_or_none(custom.get("discovered_memory_mib")),
            "gpu_count": _int_or_none(custom.get("discovered_gpu_count")),
        },
        "controller": {
            "address": settings["controller_address"],
            "slurmctld_port": settings["slurmctld_port"],
        },
    }


def _int_or_none(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def node_facts(nb, client_address, settings):
    device, address_obj = device_for_address(nb, client_address, settings["role_slug"])
    interfaces = nb.list(f"/api/dcim/interfaces/?device_id={device['id']}")
    addresses = nb.list(f"/api/ipam/ip-addresses/?device_id={device['id']}")
    return shape_facts(device, address_obj, interfaces, addresses, settings)


# ---------------------------------------------------------------------------
# Writes from a node: validated, whitelisted, about the caller only.
# ---------------------------------------------------------------------------

def validate_convergence(body) -> dict:
    if not isinstance(body, dict):
        raise BadRequest("body must be a JSON object")
    result = body.get("result")
    if result not in ("success", "failed"):
        raise BadRequest("result must be 'success' or 'failed'")
    sha = str(body.get("git_sha", "unknown"))
    if not _SHA.match(sha):
        raise BadRequest("git_sha is not a commit id")
    tag = str(body.get("image_tag", "unknown"))
    if not _TAG.match(tag):
        raise BadRequest("image_tag is not an image reference")
    try:
        duration = round(float(body.get("duration_seconds")), 3)
    except (TypeError, ValueError):
        raise BadRequest("duration_seconds must be a number") from None
    if not 0 <= duration < 86400:
        raise BadRequest("duration_seconds out of range")
    finished = str(body.get("finished_at", ""))
    if not _STAMP.match(finished):
        raise BadRequest("finished_at must be an RFC 3339 UTC timestamp")
    run_id = str(body.get("run_id", ""))
    if not _RUN.match(run_id):
        raise BadRequest("run_id is malformed")
    failed_task = str(body.get("failed_task") or "")
    if not _TASK.match(failed_task):
        raise BadRequest("failed_task is malformed")
    fields = {
        "last_git_sha": sha,
        "image_tag": tag,
        "convergence_result": result,
        "convergence_duration_seconds": f"{duration:.3f}",
        "last_converged_at": finished,
        "convergence_run_id": run_id,
        "convergence_failed_task": failed_task,
    }
    assert set(fields) == set(CONVERGENCE_FIELDS)
    return fields


_BURNIN_CHECKS = ("cpu", "memory", "disk")


def validate_burnin(body) -> dict:
    """Accept measurements only. A node-supplied verdict is dropped.

    The gate recomputes pass/fail from these numbers against thresholds held
    in the repository; a `passed: true` sent by the node it judges would be
    the one input the gate must not trust.
    """
    if not isinstance(body, dict):
        raise BadRequest("body must be a JSON object")
    checks = body.get("checks")
    if not isinstance(checks, dict) or set(checks) != set(_BURNIN_CHECKS):
        raise BadRequest(f"checks must be exactly {_BURNIN_CHECKS}")
    clean = {}
    for name in _BURNIN_CHECKS:
        check = checks[name]
        if not isinstance(check, dict):
            raise BadRequest(f"checks.{name} must be an object")
        kept = {}
        for key, value in check.items():
            if key in ("passed", "verdict", "ok"):
                continue
            if not re.match(r"^[a-z_]{1,48}$", key):
                raise BadRequest(f"checks.{name}.{key} is not a measurement name")
            if isinstance(value, bool) or value is None:
                kept[key] = value
            elif isinstance(value, (int, float)):
                kept[key] = value
            elif isinstance(value, str) and len(value) <= 256:
                kept[key] = value
            else:
                raise BadRequest(f"checks.{name}.{key} is not a scalar")
        clean[name] = kept
    stamp = str(body.get("reported_at", ""))
    if not _STAMP.match(stamp):
        raise BadRequest("reported_at must be an RFC 3339 UTC timestamp")
    tag = str(body.get("image_tag", "unknown"))
    if not _TAG.match(tag):
        raise BadRequest("image_tag is not an image reference")
    return {
        "burnin_results": {"schema": 1, "image_tag": tag, "reported_at": stamp, "checks": clean},
        "burnin_reported_at": stamp,
    }


# ---------------------------------------------------------------------------
# Head-node observability.
# ---------------------------------------------------------------------------

def _label(value) -> str:
    return str(value if value is not None else "").replace("\\", "\\\\").replace('"', '\\"')


def _epoch(stamp):
    if not stamp or not _STAMP.match(str(stamp)):
        return None
    return time.mktime(time.strptime(str(stamp)[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone


def fleet(nb, role_slug):
    """[(device, hostname, address)] for every compute device."""
    devices = nb.list(f"/api/dcim/devices/?role={role_slug}")
    names = {}
    for ip in nb.list("/api/ipam/ip-addresses/?assigned_to_interface=true"):
        if not ip.get("dns_name"):
            continue
        device_ref = (ip.get("assigned_object") or {}).get("device") or {}
        if "id" in device_ref:
            names[device_ref["id"]] = (_short(ip["dns_name"]), ip["address"].split("/")[0])
    return [(d, *names.get(d["id"], (None, None))) for d in devices]


def render_metrics(rows) -> str:
    out = [
        "# HELP cluster_node_last_converged_timestamp_seconds When the node last reported a pull run.",
        "# TYPE cluster_node_last_converged_timestamp_seconds gauge",
    ]
    success, duration, info = [], [], []
    for device, hostname, _address in rows:
        custom = device.get("custom_fields") or {}
        labels = f'device="{_label(device["name"])}",hostname="{_label(hostname)}"'
        stamp = _epoch(custom.get("last_converged_at"))
        out.append(f"cluster_node_last_converged_timestamp_seconds{{{labels}}} "
                   f"{stamp if stamp is not None else 0}")
        result = _value(custom.get("convergence_result"))
        success.append(f"cluster_node_convergence_success{{{labels}}} {1 if result == 'success' else 0}")
        try:
            duration.append(f"cluster_node_convergence_duration_seconds{{{labels}}} "
                            f"{float(custom.get('convergence_duration_seconds'))}")
        except (TypeError, ValueError):
            pass
        info.append(
            f'cluster_node_convergence_info{{{labels},git_sha="{_label(custom.get("last_git_sha"))}",'
            f'image_tag="{_label(custom.get("image_tag"))}",'
            f'status="{_label(_value(device.get("status")))}"}} 1')
    out += ["# HELP cluster_node_convergence_success 1 if the last pull run succeeded.",
            "# TYPE cluster_node_convergence_success gauge", *success,
            "# HELP cluster_node_convergence_duration_seconds Wall time of the last pull run.",
            "# TYPE cluster_node_convergence_duration_seconds gauge", *duration,
            "# HELP cluster_node_convergence_info Commit and image of the last pull run.",
            "# TYPE cluster_node_convergence_info gauge", *info]
    return "\n".join(out) + "\n"


def render_sd(rows, port: int):
    targets = [
        {"targets": [f"{address}:{port}"],
         "labels": {"hostname": hostname, "device": device["name"]}}
        for device, hostname, address in rows if address and hostname
    ]
    return sorted(targets, key=lambda t: t["targets"][0])


# ---------------------------------------------------------------------------
# HTTP.
# ---------------------------------------------------------------------------

def make_handler(nb, settings):
    class Handler(BaseHTTPRequestHandler):
        server_version = "cluster-node-api/1"

        def log_message(self, fmt, *args):  # journald adds the timestamp
            sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

        def _send(self, status, body, content_type="application/json"):
            payload = body if isinstance(body, bytes) else (
                json.dumps(body, sort_keys=True).encode() if content_type == "application/json"
                else body.encode())
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                raise BadRequest("missing or oversized body")
            try:
                return json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                raise BadRequest("body is not JSON") from None

        def _guard(self, fn):
            try:
                fn()
            except BadRequest as exc:
                self._send(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            except (NotANode, ValueError) as exc:
                self._send(HTTPStatus.FORBIDDEN, {"error": str(exc)})
            except urllib.error.URLError as exc:
                self._send(HTTPStatus.BAD_GATEWAY, {"error": f"netbox: {exc}"})

        def do_GET(self):  # noqa: N802
            client = self.client_address[0]
            if self.path == "/v1/self":
                self._guard(lambda: self._send(HTTPStatus.OK, node_facts(nb, client, settings)))
            elif self.path == "/metrics":
                self._guard(lambda: self._send(
                    HTTPStatus.OK, render_metrics(fleet(nb, settings["role_slug"])),
                    "text/plain; version=0.0.4"))
            elif self.path == "/v1/sd/node-exporter":
                self._guard(lambda: self._send(
                    HTTPStatus.OK, render_sd(fleet(nb, settings["role_slug"]),
                                             settings["node_exporter_port"])))
            elif self.path == "/healthz":
                self._send(HTTPStatus.OK, {"ok": True})
            else:
                self._send(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            client = self.client_address[0]
            validators = {"/v1/self/convergence": validate_convergence,
                          "/v1/self/burnin": validate_burnin}
            validator = validators.get(self.path)
            if validator is None:
                self._send(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return

            def write():
                fields = validator(self._body())
                device, _ = device_for_address(nb, client, settings["role_slug"])
                nb.patch(f"/api/dcim/devices/{device['id']}/", {"custom_fields": fields})
                self._send(HTTPStatus.OK, {"device": device["name"], "written": sorted(fields)})

            self._guard(write)

    return Handler


def main():
    settings = {
        "role_slug": os.environ.get("NODE_API_ROLE", "compute"),
        "controller_address": os.environ["NODE_API_CONTROLLER_ADDRESS"],
        "slurmctld_port": int(os.environ.get("NODE_API_SLURMCTLD_PORT", "6817")),
        "node_exporter_port": int(os.environ.get("NODE_API_NODE_EXPORTER_PORT", "9100")),
    }
    env_file = os.environ.get("NODE_API_NETBOX_ENV", "/etc/cluster-lab/netbox.env")
    values = {}
    with open(env_file, encoding="utf-8") as handle:
        for line in handle:
            key, _, value = line.strip().partition("=")
            values[key] = value
    token = f"nbt_{values['SUPERUSER_API_KEY']}.{values['SUPERUSER_API_TOKEN']}"
    nb = NetBox(os.environ.get("NODE_API_NETBOX_URL", "http://127.0.0.1:8000"), token)
    bind = os.environ["NODE_API_BIND"]
    port = int(os.environ.get("NODE_API_PORT", "8002"))
    server = ThreadingHTTPServer((bind, port), make_handler(nb, settings))
    print(f"cluster-node-api listening on {bind}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":  # pragma: no cover
    main()
