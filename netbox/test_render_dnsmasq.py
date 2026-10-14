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
import tempfile
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
        self.assertEqual(lines, ["52:54:00:00:00:01,10.42.0.20,cn01\n"])

    def test_guid_entry_renders_an_option61_form(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": None, "ib_guid": PORT_GUID},
        ])
        client_id = ib_guid.guid_to_client_id(PORT_GUID)
        self.assertEqual(
            lines, [f"id:{client_id},10.42.0.20,cn01\n"])

    def test_an_interface_with_both_identifiers_gets_both_lines(self):
        lines = render_dnsmasq.render_entries([
            {"hostname": "cn01", "ip": "10.42.0.20",
             "mac": "52:54:00:00:00:01", "ib_guid": PORT_GUID},
        ])
        self.assertEqual(len(lines), 2)
        self.assertTrue(any(line.startswith("52:") for line in lines))
        self.assertTrue(any(line.startswith("id:") for line in lines))

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

    def test_output_is_readable_by_unprivileged_dnsmasq(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "netbox-hosts.conf"
            self.assertTrue(render_dnsmasq.write_output(target, ["entry\n"]))
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            target.chmod(0o600)
            self.assertTrue(render_dnsmasq.write_output(target, ["entry\n"]))
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            self.assertFalse(render_dnsmasq.write_output(target, ["entry\n"]))


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

    def test_named_provisioning_address_wins_over_discovery_lease(self):
        temporary = self._Obj(address="10.42.0.135/24", dns_name="")
        canonical = self._Obj(address="10.42.0.20/24", dns_name="cn01.lab.internal")
        self.assertIs(
            render_dnsmasq.reservation_address(
                [temporary, canonical], "provisioning"),
            canonical,
        )

    def test_other_interfaces_keep_their_first_address(self):
        first = self._Obj(address="10.43.0.20/24", dns_name="")
        second = self._Obj(address="10.43.0.120/24", dns_name="cn01-ib")
        self.assertIs(
            render_dnsmasq.reservation_address([first, second], "ib0"),
            first,
        )


class RenderHostsTest(unittest.TestCase):
    ENTRIES = [
        {"hostname": "cn02", "ip": "10.42.0.21",
         "mac": "52:54:00:00:00:02", "ib_guid": None},
        {"hostname": "cn01", "ip": "10.42.0.20",
         "mac": "52:54:00:00:00:01", "ib_guid": None},
        # An IB address must not become a second answer for the name.
        {"hostname": "cn01", "ip": "10.43.0.20",
         "mac": None, "ib_guid": PORT_GUID},
    ]

    def test_provisioning_addresses_with_short_and_qualified_names(self):
        self.assertEqual(
            render_dnsmasq.render_hosts(self.ENTRIES, "lab.internal"),
            ["10.42.0.20\tcn01 cn01.lab.internal\n",
             "10.42.0.21\tcn02 cn02.lab.internal\n"])

    def test_no_domain_renders_the_short_name_only(self):
        self.assertEqual(render_dnsmasq.render_hosts(self.ENTRIES[:1], ""),
                         ["10.42.0.21\tcn02\n"])


class EtcHostsBlockTest(unittest.TestCase):
    WSL = "127.0.0.1\tlocalhost\n::1\tip6-localhost\n"
    LINES = ["10.42.0.20\tcn01 cn01.lab.internal\n"]

    def test_block_is_appended_and_the_rest_is_kept(self):
        merged = render_dnsmasq.merge_hosts_block(self.WSL, self.LINES)
        self.assertTrue(merged.startswith(self.WSL))
        self.assertIn(render_dnsmasq.HOSTS_BEGIN + self.LINES[0]
                      + render_dnsmasq.HOSTS_END, merged)

    def test_block_is_replaced_in_place_not_duplicated(self):
        once = render_dnsmasq.merge_hosts_block(self.WSL + "# tail\n", ["old\n"])
        twice = render_dnsmasq.merge_hosts_block(once, self.LINES)
        self.assertEqual(twice.count(render_dnsmasq.HOSTS_BEGIN), 1)
        self.assertNotIn("old\n", twice)
        self.assertTrue(twice.endswith("# tail\n" + render_dnsmasq.HOSTS_BEGIN
                                       + self.LINES[0] + render_dnsmasq.HOSTS_END))

    def test_file_without_a_final_newline_stays_intact(self):
        merged = render_dnsmasq.merge_hosts_block("127.0.0.1 localhost", self.LINES)
        self.assertTrue(merged.startswith("127.0.0.1 localhost\n# BEGIN"))

    def test_sync_reports_a_change_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "netbox-hosts"
            target = Path(tmp) / "hosts"
            source.write_text("".join(self.LINES))
            target.write_text(self.WSL)
            self.assertTrue(render_dnsmasq.sync_etc_hosts(source, target))
            self.assertFalse(render_dnsmasq.sync_etc_hosts(source, target))
            self.assertIn("cn01.lab.internal", target.read_text())


if __name__ == "__main__":
    unittest.main()
