#!/usr/bin/env python3
"""Validate public Android client configuration without logging API key values.

The private build-settings file contains only the publishable Android TN10 key.
Keep it outside the source checkout. The one-time bootstrap can recover this
public identifier from a previously working, locally held Android APK; it never
copies the separately registered browser-extension key or accepts server keys.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import zipfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def check_mainnet():
    # Only the public, credential-free app route is probed. A successful local
    # build must not conceal a missing server configuration or wrong network.
    with urllib.request.urlopen('https://kaspire.kaslab.space/api/kasparocket/pro-api/protocol', timeout=20) as response:
        protocol = json.load(response)
    if protocol.get('network') != 'mainnet' or not {'read', 'trade'}.issubset(set(protocol.get('partner', {}).get('scopes', []))):
        raise ValueError('KaspaRocket Mainnet gateway is not ready for read/trade.')
DEFAULT_CONFIG = Path('/srv/kaspire/release-signing/android-public-clients.json')
KEY_PATTERN = re.compile(rb'krpub_test_[A-Za-z0-9_-]{16,}')


def validate_key(key):
    if not isinstance(key, str) or not KEY_PATTERN.fullmatch(key.encode('ascii', errors='replace')):
        raise ValueError('A publishable Android TN10 client key is required; server keys are forbidden.')
    return key


def load_config(path):
    data = json.loads(path.read_text())
    if set(data) != {'KASPAROCKET_API_KEY'}:
        raise ValueError('Unexpected Android client configuration fields.')
    return validate_key(data['KASPAROCKET_API_KEY'])


def bootstrap(apk, output):
    if output.resolve().is_relative_to(ROOT):
        raise ValueError('Store local build settings outside the source checkout.')
    with zipfile.ZipFile(apk) as archive:
        keys = set(KEY_PATTERN.findall(archive.read('lib/arm64-v8a/libapp.so')))
    if len(keys) != 1:
        raise ValueError('The reference APK must contain exactly one publishable Android TN10 key.')
    key = validate_key(keys.pop().decode('ascii'))
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump({'KASPAROCKET_API_KEY': key}, stream)
        stream.write('\n')
    return key


def verify_apk(apk, key):
    session_source = ROOT / 'apps/mobile_flutter/lib/src/services/dapp_session_service.dart'
    match = re.search(r"static const projectId = '([a-f0-9]{32})'", session_source.read_text())
    if match is None:
        raise ValueError('Missing pinned WalletConnect project identity.')
    with zipfile.ZipFile(apk) as archive:
        for abi in ('arm64-v8a', 'armeabi-v7a'):
            app = archive.read(f'lib/{abi}/libapp.so')
            if re.search(rb'kr_live_[A-Za-z0-9_-]{16,}', app):
                raise ValueError('Server-only KaspaRocket credentials must never be packaged in Android.')
            if set(KEY_PATTERN.findall(app)) != {key.encode('ascii')}:
                raise ValueError(f'{abi}: APK does not contain the configured Android client key.')
            if match.group(1).encode('ascii') not in app:
                raise ValueError(f'{abi}: APK does not contain the pinned WalletConnect identity.')
            if not archive.read(f'lib/{abi}/libkaspa_secure_core.so'):
                raise ValueError(f'{abi}: missing Rust signing core.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('bootstrap', 'check', 'verify-apk', 'check-mainnet'))
    parser.add_argument('--configuration', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--apk', type=Path)
    args = parser.parse_args()
    if args.command == 'check-mainnet':
        check_mainnet()
        print('KaspaRocket Mainnet gateway: read/trade ready; server key is not packaged.')
        return
    if args.command in ('bootstrap', 'verify-apk') and args.apk is None:
        parser.error('--apk is required')
    key = bootstrap(args.apk, args.configuration) if args.command == 'bootstrap' else load_config(args.configuration)
    if args.command == 'verify-apk':
        verify_apk(args.apk, key)
    fingerprint = hashlib.sha256(key.encode('ascii')).hexdigest()[:12]
    print(f'Android client configuration: OK (publishable TN10, fingerprint {fingerprint}); {args.command} passed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile):
        print('Android client configuration check failed; no key values were logged.', file=sys.stderr)
        sys.exit(1)
