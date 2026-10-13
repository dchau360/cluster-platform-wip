import tempfile
import unittest
from pathlib import Path

from address_plan import load_plan, node_address, validate_capacity


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


if __name__ == "__main__":
    unittest.main()
