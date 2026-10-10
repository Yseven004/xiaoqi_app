from __future__ import annotations

import unittest

from entrypoint import config_for_domains


class ProxyConfigTests(unittest.TestCase):
    def test_config_allows_only_exact_requested_domains_and_web_ports(self) -> None:
        config = config_for_domains(["api.example.com", "files.example.net"])
        self.assertIn("acl allowed_domains dstdomain api.example.com files.example.net", config)
        self.assertIn("acl Safe_ports port 80 443", config)
        self.assertIn("http_access deny denied_destinations", config)
        self.assertIn("http_access deny all", config)
        self.assertNotIn("dstdomain .example.com", config)

    def test_config_rejects_wildcards_and_private_addresses(self) -> None:
        for domain in ("*.example.com", "127.0.0.1", "bad domain"):
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                config_for_domains([domain])


if __name__ == "__main__":
    unittest.main()
