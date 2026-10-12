#!/usr/bin/env python3
"""InfiniBand GUID discovery and DHCP option-61 client-id reservations.

Honesty first. This code has never run against InfiniBand hardware. The lab
is virtio NICs on one workstation: there is no HCA, no fabric and no real
port GUID anywhere in it. Everything here is written to do the real work on
a real machine, and every test that exercises it uses **synthetic** GUID
data from the locally-administered-style range. `docs/ib-and-dhcp-option61.md`
says the same thing where a reader will find it, because a gap that is
disclosed is a design decision and a gap that is found is a credibility
failure.

Two jobs, one module, because they are two ends of the same fact:

* `discover_ports()` reads port GUIDs from sysfs. That is the scrape a node
  with an HCA would run, and the discovery image calls it when sysfs has an
  `infiniband` class at all.
* `reservation_line()` turns a port GUID into the `dhcp-host=id:...` line
  dnsmasq needs for a client-identifier (option-61) reservation, so a node
  that identifies itself by GUID rather than by MAC still gets the address
  its NetBox interface owns.

Nothing here is imported at image-build time or at dnsmasq-render time with
a live NetBox; both callers pass plain values, which is what makes the unit
tests possible without a fabric.
"""

from __future__ import annotations

import re
from pathlib import Path

# An uninitialized or masked port reports all zeroes. A reservation keyed on
# it would be a reservation every such port matches, so it is treated as
# "no GUID" rather than as a value.
ZERO_GUID = "0000:0000:0000:0000"

_HEX = re.compile(r"^[0-9a-f]+$")


def _clean(value: str | None) -> str:
    if value is None:
        return ""
    return value.strip().lower()


def normalize_guid(value: str | None) -> str | None:
    """Return a 64-bit GUID as ``xxxx:xxxx:xxxx:xxxx``, or ``None``.

    Accepts the colon-separated form sysfs uses, dash-, dot- or
    space-separated forms, a bare 16-hex string, and an ``0x`` prefix.
    Returns ``None`` for anything that is not a 64-bit GUID, and for the
    all-zero GUID, which is what an uninitialized port reports.
    """
    text = _clean(value)
    if text.startswith("0x"):
        text = text[2:]
    text = re.sub(r"[.:\s-]", "", text)
    if len(text) != 16 or not _HEX.match(text):
        return None
    guid = ":".join(text[i:i + 4] for i in range(0, 16, 4))
    return None if guid == ZERO_GUID else guid


def normalize_gid(value: str | None) -> str | None:
    """Return a 128-bit GID as eight colon-separated groups, or ``None``."""
    text = _clean(value)
    if text.startswith("0x"):
        text = text[2:]
    text = re.sub(r"[.:\s-]", "", text)
    if len(text) != 32 or not _HEX.match(text):
        return None
    return ":".join(text[i:i + 4] for i in range(0, 32, 4))


def gid_to_port_guid(gid: str | None) -> str | None:
    """The port GUID carried in GID 0: its low 64 bits.

    On an InfiniBand link the node's GID 0 *is* the port GUID in its low
    half, which is why this is a real conversion and not a guess. On a RoCE
    link GID 0 is derived from the MAC, so a caller that needs that form
    should read ``port_guid``/``node_guid`` instead.
    """
    normalized = normalize_gid(gid)
    if normalized is None:
        return None
    low = "".join(normalized.split(":")[4:])
    return normalize_guid(low)


def guid_to_client_id(guid: str | None) -> str | None:
    """The DHCP option-61 client-id for a port GUID, as dnsmasq hex bytes.

    dnsmasq matches ``dhcp-host=id:<client-id>`` against option 61. This
    emits the eight GUID bytes in colon-hex. What an IPoIB DHCP client
    actually puts in option 61 depends on the client, and this mapping has
    not been validated on hardware; the honest statement is that it is the
    convention this lab assumes.
    """
    normalized = normalize_guid(guid)
    if normalized is None:
        return None
    raw = normalized.replace(":", "")
    return ":".join(raw[i:i + 2] for i in range(0, 16, 2))


def reservation_line(hostname: str | None, ip: str | None,
                     guid: str | None) -> str | None:
    """A ``dhcp-host=id:...,name,ip`` line, or ``None`` if it is unusable."""
    client_id = guid_to_client_id(guid)
    if client_id is None or not hostname or not ip:
        return None
    return f"dhcp-host=id:{client_id},{hostname},{ip}\n"


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def discover_ports(root: str | Path = "/sys/class/infiniband") -> list[dict]:
    """Every IB port under ``root``, with its GUIDs.

    The sysfs layout is the one the kernel exposes:

        <root>/<device>/node_guid
        <root>/<device>/ports/<port>/gids/0
        <root>/<device>/ports/<port>/state
        <root>/<device>/ports/<port>/rate

    The port GUID is the low 64 bits of GID 0. A port whose GID is missing
    or all-zero is still reported, with ``port_guid`` ``None``, because
    "this port has no usable GUID" is itself a fact worth carrying.
    """
    base = Path(root)
    if not base.is_dir():
        return []
    ports: list[dict] = []
    for device in sorted(base.iterdir(), key=lambda p: p.name):
        if not device.is_dir():
            continue
        node_guid = normalize_guid(_read(device / "node_guid"))
        ports_dir = device / "ports"
        if not ports_dir.is_dir():
            continue
        for port in sorted(ports_dir.iterdir(), key=lambda p: p.name):
            if not port.is_dir():
                continue
            gid0 = normalize_gid(_read(port / "gids" / "0"))
            ports.append({
                "device": device.name,
                "port": port.name,
                "node_guid": node_guid,
                # Prefer the explicit file when a driver exposes it, then the
                # low half of GID 0.
                "port_guid": (normalize_guid(_read(port / "port_guid"))
                              or gid_to_port_guid(gid0)),
                "gid": gid0,
                "state": _read(port / "state").strip(),
                "rate": _read(port / "rate").strip(),
            })
    return ports


def render_reservations(entries: list[dict]) -> list[str]:
    """Sorted ``dhcp-host`` lines for entries that carry a usable GUID.

    Each entry is a mapping with ``hostname``, ``ip`` and ``ib_guid``. An
    entry without a usable GUID is skipped, not guessed at.
    """
    lines = []
    for entry in entries:
        line = reservation_line(
            entry.get("hostname"), entry.get("ip"), entry.get("ib_guid"))
        if line is not None:
            lines.append(line)
    return sorted(set(lines))


if __name__ == "__main__":  # pragma: no cover - a debugging convenience
    import json
    import sys

    root = sys.argv[1] if len(sys.argv) > 1 else "/sys/class/infiniband"
    print(json.dumps(discover_ports(root), indent=2))
