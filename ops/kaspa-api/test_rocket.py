import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gateway', Path(__file__).with_name('gateway.py'))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

class RocketTests(unittest.TestCase):
    def test_allowlist_never_exposes_admin_creation_or_foreign_network(self):
        for method, path in [('POST','/pro-api/submit'), ('POST','/pro-api/plan/trade'), ('GET','/pro-api/protocol'), ('GET','/api/tokens')]:
            self.assertTrue(gateway._rocket_route(method, path))
        for method, path in [('POST','/pro-api/create'), ('POST','/api/tokens'), ('GET','/admin/keys'), ('GET','//evil.example/x'), ('GET','/api/../admin'), ('GET','/pro-api/tokens/kaspatest:qtest')]:
            self.assertFalse(gateway._rocket_route(method, path))

    def test_public_catalogue_reuses_partner_quota_but_wallet_reads_do_not(self):
        gateway._rocket_cache.clear()
        with patch.object(gateway, '_request', return_value=(200, {}, b'[]')) as request:
            gateway._rocket_read('/api/tokens')
            gateway._rocket_read('/api/tokens')
            self.assertEqual(request.call_count, 1)
            gateway._rocket_read('/pro-api/tokens/kaspa:qtest')
            gateway._rocket_read('/pro-api/tokens/kaspa:qtest')
            self.assertEqual(request.call_count, 3)
