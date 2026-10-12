#!/usr/bin/env python3
"""Unit tests for the dnsmasq renderer's reservation lines.

The role file is loaded by path because it is deployed as
`/usr/local/sbin/render-netbox-dnsmasq`, not as an importable package. It
must import without `pynetbox` (the NetBox client is imported inside
`main()`), which these tests also prove.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROLE_FILE = (HERE.parent / "ansible" / "roles" / "dnsmasq"
             / "files" / "render_dnsmasq.py")

sys.path.insert(0, str(HERE))
import ib_guid  # noqa: E402

_spec = importlib.util.spec_from_file_location("render_dnsmasq", ROLE_FILE)
render_dnsmasq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render_dnsmasq)

# Synthetic GUIDs, same convention as test_ib_guid.py.
PORT_GUID = "0200:0042:0000:0002"


class RenderEntriesTest(unittest.TestCase):
    def test_mac_entry_renders_the_classic_form(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": "52:54:00:00:00:01", "ib_guid": None},
        ])
        self.assertEqual(lines, ["dhcp-host=52:54:00:00:00:01,cn01,10.42.0.20\n"])

    def test_guid_entry_renders_an_option61_form(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": None, "ib_guid": PORT_GUID},
        ])
        client_id = ib_guid.guid_to_client_id(PORT_GUID)
        self.assertEqual(
            lines, [f"dhcp-host=id:{client_id},cn01,10.42.0.20\n"])

    def test_an_interface_with_both_identifiers_gets_both_lines(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": "52:54:00:00:00:01", "ib_guid": PORT_GUID},
        ])
        self.assertEqual(len(lines), 2)
        self.assertTrue(any(line.startswith("dhcp-host=52:") for line in lines))
        self.assertTrue(any(line.startswith("dhcp-host=id:") for line in lines))

    def test_unusable_guid_adds_nothing(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": None, "ib_guid": "0000:0000:0000:0000"},
        ])
        self.assertEqual(lines, [])

    def test_incomplete_entry_is_skipped(self):
        self.assertEqual(render_dnsmasq.render_entries([
            {"hostname": "", "ip": "10.42.0.20",
             "mac": "52:54:00:00:00:01", "ib_guid": None},
            {"hostname": "cn02", "ip": "",
             "mac": "52:54:00:00:00:02", "ib_guid": None},
        ]), [])

    def test_output_is_sorted_and_deduplicated(self):
        entry = {"hostname": "cn01", "ip": "10.42.0.20",
                 "mac": "52:54:00:00:00:01", "ib_guid": PORT_GUID}
        self.assertEqual(render_dnsmasq.render_entries([entry, entry]),
                         render_dnsmasq.render_entries([entry]))


class EntryHostnameTest(unittest.TestCase):
    """The DHCP hostname is the address's DNS name, not the rack position."""

    class _Obj:
        def __init__(self, **kw):
            self.__dict__.update(kw)

    def test_dns_name_wins_over_the_device_name(self):
        address = self._Obj(dns_name="cn01.lab.internal")
        device = self._Obj(name="rack-a-u01")
        self.assertEqual(render_dnsmasq.entry_hostname(address, device), "cn01")

    def test_no_dns_name_falls_back_to_the_device_name(self):
        address = self._Obj(dns_name="")
        device = self._Obj(name="rack-a-u01")
        self.assertEqual(render_dnsmasq.entry_hostname(address, device), "rack-a-u01")


if __name__ == "__main__":
    unittest.main()
