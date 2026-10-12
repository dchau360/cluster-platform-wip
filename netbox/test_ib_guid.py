#!/usr/bin/env python3
"""Unit tests for the InfiniBand GUID / DHCP option-61 code.

Every GUID in this file is synthetic. No InfiniBand hardware has ever been
attached to this lab, so the tests construct a small sysfs tree and feed
made-up GUIDs through the same functions a real HCA's sysfs tree would use.
Running the same tests on a machine with a fabric would not change a line;
that is the point of keeping the conversion pure.

Run with:  python3 -m unittest discover -s netbox -p 'test_*.py'
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ib_guid  # noqa: E402

# A synthetic node/port pair. The 64-bit form is deliberately written in the
# four-group shape sysfs uses; the byte form the client-id needs is derived,
# never typed as a literal.
NODE_GUID = "0200:0042:0000:0001"
PORT_GUID = "0200:0042:0000:0002"
GID0 = "fe800000000000000200004200000002"


class NormalizeGuidTest(unittest.TestCase):
    def test_accepts_the_shapes_a_reader_will_find(self):
        for raw in (NODE_GUID, NODE_GUID.replace(":", ""),
                    "0x" + NODE_GUID.replace(":", ""),
                    "0200-0042-0000-0001", "0200.0042.0000.0001",
                    NODE_GUID.upper(), f"  {NODE_GUID}\n"):
            with self.subTest(raw=raw):
                self.assertEqual(ib_guid.normalize_guid(raw), NODE_GUID)

    def test_rejects_the_all_zero_guid(self):
        # An uninitialized port reports zeroes. A reservation keyed on it
        # would match every uninitialized port, so it must not normalize.
        self.assertIsNone(ib_guid.normalize_guid("0000:0000:0000:0000"))
        self.assertIsNone(ib_guid.normalize_guid("0000000000000000"))

    def test_rejects_malformed_and_missing(self):
        for raw in (None, "", "abcd", "gggg:0000:0000:0001",
                    "0200:0042:0000", NODE_GUID + ":0001"):
            with self.subTest(raw=raw):
                self.assertIsNone(ib_guid.normalize_guid(raw))


class GidTest(unittest.TestCase):
    def test_port_guid_is_the_low_half_of_gid_zero(self):
        self.assertEqual(ib_guid.gid_to_port_guid(GID0), PORT_GUID)

    def test_rejects_a_gid_that_is_not_128_bits(self):
        self.assertIsNone(ib_guid.gid_to_port_guid(NODE_GUID))
        self.assertIsNone(ib_guid.gid_to_port_guid(None))


class ClientIdTest(unittest.TestCase):
    def test_client_id_is_the_eight_guid_bytes(self):
        self.assertEqual(ib_guid.guid_to_client_id(NODE_GUID).split(":"),
                         ["02", "00", "00", "42", "00", "00", "00", "01"])

    def test_client_id_is_none_for_an_unusable_guid(self):
        self.assertIsNone(ib_guid.guid_to_client_id("0000:0000:0000:0000"))
        self.assertIsNone(ib_guid.guid_to_client_id("nonsense"))


class ReservationLineTest(unittest.TestCase):
    def test_line_is_the_dnsmasq_option61_form(self):
        client_id = ib_guid.guid_to_client_id(PORT_GUID)
        self.assertEqual(
            ib_guid.reservation_line("cn01", "10.42.0.20", PORT_GUID),
            f"dhcp-host=id:{client_id},cn01,10.42.0.20\n")

    def test_line_is_none_when_anything_is_missing(self):
        self.assertIsNone(ib_guid.reservation_line("", "10.42.0.20", PORT_GUID))
        self.assertIsNone(ib_guid.reservation_line("cn01", "", PORT_GUID))
        self.assertIsNone(ib_guid.reservation_line(
            "cn01", "10.42.0.20", "0000:0000:0000:0000"))


class DiscoverPortsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self._port("mlx5_0", "1", gid=GID0, node=NODE_GUID,
                   state="4: ACTIVE", rate="100 Gb/sec (4X EDR)")
        # A second port with an all-zero GID, which is what an uninitialized
        # port looks like. It must be reported, with no port GUID.
        self._port("mlx5_1", "1", gid="00000000000000000000000000000000",
                   node="0000000000000000", state="1: DOWN", rate="")

    def _port(self, device, port, gid, node, state, rate):
        base = self.root / device
        (base / "ports" / port / "gids").mkdir(parents=True, exist_ok=True)
        (base / "node_guid").write_text(node + "\n")
        (base / "ports" / port / "gids" / "0").write_text(gid + "\n")
        (base / "ports" / port / "state").write_text(state + "\n")
        (base / "ports" / port / "rate").write_text(rate + "\n")

    def test_reads_every_port_with_its_guids(self):
        ports = ib_guid.discover_ports(self.root)
        self.assertEqual([p["device"] for p in ports], ["mlx5_0", "mlx5_1"])
        first = ports[0]
        self.assertEqual(first["port"], "1")
        self.assertEqual(first["node_guid"], NODE_GUID)
        self.assertEqual(first["port_guid"], PORT_GUID)
        self.assertEqual(first["state"], "4: ACTIVE")
        self.assertIn("EDR", first["rate"])

    def test_all_zero_gid_is_reported_without_a_port_guid(self):
        second = ib_guid.discover_ports(self.root)[1]
        self.assertIsNone(second["port_guid"])
        self.assertIsNone(second["node_guid"])

    def test_missing_sysfs_root_is_empty_not_an_error(self):
        self.assertEqual(ib_guid.discover_ports(self.root / "absent"), [])


class RenderReservationsTest(unittest.TestCase):
    def test_sorts_dedupes_and_skips_unusable_guid(self):
        entries = [
            {"hostname": "cn02", "ip": "10.42.0.21", "ib_guid": NODE_GUID},
            {"hostname": "cn01", "ip": "10.42.0.20", "ib_guid": PORT_GUID},
            {"hostname": "cn01", "ip": "10.42.0.20", "ib_guid": PORT_GUID},
            {"hostname": "cn03", "ip": "10.42.0.22",
             "ib_guid": "0000:0000:0000:0000"},
        ]
        lines = ib_guid.render_reservations(entries)
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines, sorted(lines))
        self.assertTrue(all(line.startswith("dhcp-host=id:") for line in lines))
        self.assertFalse(any("cn03" in line for line in lines))


if __name__ == "__main__":
    unittest.main()
