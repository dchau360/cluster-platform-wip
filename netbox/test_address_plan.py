import os
import tempfile
import unittest
from pathlib import Path

from address_plan import conflicts, load_plan, node_address, shell_environment, validate_capacity


class AddressPlanTest(unittest.TestCase):
    def test_static_allocations_do_not_overlap_dynamic_pool_at_100_or_500(self):
        _, prefixes, _, _, _ = load_plan()
        self.assertEqual(22, prefixes["provisioning"].prefixlen)
        validate_capacity((100, 500))

    def test_old_plan_fails_at_node_81(self):
        old = """
prefixes:
  bmc: 10.41.0.0/24
  provisioning: 10.42.0.0/24
  data: 10.43.0.0/24
address_plan:
  provisioning_gateway_offset: 1
  node_offset: 19
  dynamic_pool: 10.42.0.100-10.42.0.199
  dynamic_lease: 10m
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "definition.yml"
            path.write_text(old)
            with self.assertRaisesRegex(ValueError, "10.42.0.100.*overlaps"):
                validate_capacity((100,), path)


class SubnetOverrideTest(unittest.TestCase):
    def setUp(self):
        self._saved = os.environ.pop("PROV_SUBNET", None)

    def tearDown(self):
        os.environ.pop("PROV_SUBNET", None)
        if self._saved is not None:
            os.environ["PROV_SUBNET"] = self._saved

    def test_subnet_moves_every_provisioning_address_and_keeps_offsets(self):
        os.environ["PROV_SUBNET"] = "10.46.0.0/22"
        env = shell_environment()
        for expected in ("PROV_CIDR=10.46.0.0/22", "PROV_GW=10.46.0.1",
                         "PROV_DHCP_START=10.46.3.20", "PROV_DHCP_END=10.46.3.250"):
            self.assertIn(expected, env)
        self.assertEqual("10.46.0.20", str(node_address(1)))
        # The BMC and data prefixes are not part of the segment and stay put.
        self.assertEqual("10.40.0.20", str(node_address(1, network="bmc")))
        validate_capacity((100, 500))

    def test_larger_subnet_is_accepted(self):
        validate_capacity((100, 500), subnet="10.50.0.0/20")

    def test_unusable_subnets_are_refused_with_the_reason(self):
        for subnet, reason in (("10.46.0.0/24", "smaller"),
                               ("10.46.0.1/22", "did you mean 10.46.0.0/22"),
                               ("198.51.100.0/22", "must be private"),
                               ("10.48.0.0/22", "overlaps the data prefix"),
                               ("nonsense", "not an IPv4 network")):
            with self.subTest(subnet=subnet), self.assertRaisesRegex(ValueError, reason):
                load_plan(subnet=subnet)

    def test_conflicts_names_only_overlapping_networks(self):
        os.environ["PROV_SUBNET"] = "10.46.0.0/22"
        found = conflicts(["eth0 192.0.2.0/24", "docker:netbox 10.46.2.0/24",
                           "home-LAN 10.46.0.0/16", "garbage"])
        self.assertEqual(["docker:netbox 10.46.2.0/24", "home-LAN 10.46.0.0/16"], found)


if __name__ == "__main__":
    unittest.main()
