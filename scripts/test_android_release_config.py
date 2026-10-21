import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from io import BytesIO

SPEC = importlib.util.spec_from_file_location('release_config', Path(__file__).with_name('android_release_config.py'))
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)


class ReleaseConfigTests(unittest.TestCase):
    def test_mainnet_release_requires_live_gateway_and_trade_scope(self):
        for payload, valid in [({'network':'mainnet','partner':{'scopes':['read','trade']}}, True),
                               ({'network':'testnet-10','partner':{'scopes':['read','trade']}}, False),
                               ({'network':'mainnet','partner':{'scopes':['read']}}, False)]:
            with patch.object(config.urllib.request, 'urlopen', return_value=BytesIO(json.dumps(payload).encode())):
                if valid: config.check_mainnet()
                else:
                    with self.assertRaises(ValueError): config.check_mainnet()

    def test_server_secret_and_missing_keys_are_rejected(self):
        for key in ('', None, 'kr_live_' + 'a' * 32, 'kr_test_' + 'b' * 32):
            with self.assertRaises(ValueError):
                config.validate_key(key)

    def test_bootstrap_is_private_and_never_overwrites_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            apk, output = base / 'reference.apk', base / 'clients.json'
            key = 'krpub_test_' + 'a' * 32
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', key.encode())
            self.assertEqual(config.bootstrap(apk, output), key)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(config.load_config(output), key)
            with self.assertRaises(FileExistsError):
                config.bootstrap(apk, output)

    def test_missing_or_unexpected_settings_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'clients.json'
            for data in ({}, {'KASPAROCKET_API_KEY': ''}, {'SERVER_SECRET': 'fixture'}):
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    config.load_config(path)

    def test_apk_verification_checks_both_abis_and_pinned_walletconnect(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'apps/mobile_flutter/lib/src/services/dapp_session_service.dart'
            source.parent.mkdir(parents=True)
            project_id = 'a' * 32
            source.write_text(f"static const projectId = '{project_id}';")
            key = 'krpub_test_' + 'b' * 32

            def apk(name, invalid_abi=None, wrong_identity=False):
                path = base / name
                with zipfile.ZipFile(path, 'w') as archive:
                    for abi in ('arm64-v8a', 'armeabi-v7a'):
                        value = '' if invalid_abi == abi else key
                        identity = 'c' * 32 if wrong_identity else project_id
                        archive.writestr(f'lib/{abi}/libapp.so', f'{value}\x00{identity}')
                        archive.writestr(f'lib/{abi}/libkaspa_secure_core.so', b'native-fixture')
                return path

            with patch.object(config, 'ROOT', base):
                config.verify_apk(apk('valid.apk'), key)
                for abi in ('arm64-v8a', 'armeabi-v7a'):
                    with self.assertRaises(ValueError):
                        config.verify_apk(apk(f'bad-{abi}.apk', invalid_abi=abi), key)
                with self.assertRaises(ValueError):
                    config.verify_apk(apk('wrong-identity.apk', wrong_identity=True), key)


if __name__ == '__main__':
    unittest.main()
