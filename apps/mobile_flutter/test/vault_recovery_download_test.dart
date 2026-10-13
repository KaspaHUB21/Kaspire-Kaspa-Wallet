import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/vault_recovery_download.dart';

void main() {
  final data = <String, Object?>{
    'protocol': 'kascoven-vault-recovery-v1',
    'network': 'kaspa-mainnet',
    'type': 'time_lock',
    'vaultAddress': 'kaspa:${'a' * 61}',
    'redeemScript': 'aabb',
    'rawPayload': {'p': 'kascoven-vault', 'v': 2},
  };
  String message(
          {String name = 'kascoven-time_lock-test.json',
          Map<String, Object?>? record}) =>
      jsonEncode({
        'capability': 'test',
        'filename': name,
        'json': jsonEncode(record ?? data),
      });
  test('only the exact approved HTTPS Vault origin can export', () {
    expect(
        VaultRecoveryDownload.allowedOrigin(
            Uri.parse('https://vaults.kaslab.space/')),
        isTrue);
    for (final url in [
      'http://vaults.kaslab.space/',
      'https://vaults.kaslab.space:444/',
      'https://user@vaults.kaslab.space/',
      'https://vaults.kaslab.space.evil.example/',
      'https://gothdag.kaslab.space/'
    ]) {
      expect(VaultRecoveryDownload.allowedOrigin(Uri.parse(url)), isFalse);
    }
  });
  test('only bounded recovery JSON, safe filenames and public metadata pass',
      () {
    expect(VaultRecoveryDownload.parse(message()).fileName,
        'kascoven-time_lock-test.json');
    for (final name in [
      '../../wallet.json',
      'wallet.apk',
      'backup.json',
      'kascoven-dead_man_switch-test.json'
    ]) {
      expect(() => VaultRecoveryDownload.parse(message(name: name)),
          throwsFormatException);
    }
    for (final invalid in [
      {...data, 'protocol': 'arbitrary-download'},
      {...data, 'network': 'testnet'},
      {...data, 'vaultAddress': 'not-an-address'},
      {...data, 'extra': 'unsupported'},
      {
        ...data,
        'rawPayload': {'privateKey': 'secret'}
      },
      {...data, 'vaultName': 'x' * (VaultRecoveryDownload.maxBytes + 1)},
    ]) {
      expect(() => VaultRecoveryDownload.parse(message(record: invalid)),
          throwsFormatException);
    }
  });
  test(
      'blob export survives immediate revoke; arbitrary downloads stay blocked',
      () async {
    final script =
        VaultRecoveryDownload.script('unguessable-navigation-capability');
    final result = await Process.run('/opt/node-v22.23.1/bin/node', [
      '--input-type=module',
      '-e',
      '''
      globalThis.window = {}; window.top = window;
      globalThis.location = {origin: 'https://vaults.kaslab.space'};
      globalThis.document = {addEventListener() {}};
      let normalClicks = 0;
      globalThis.HTMLAnchorElement = class {click() {normalClicks++;}};
      const messages = [];
      globalThis.KaspireVaultRecovery = {postMessage(v) {messages.push(JSON.parse(v));}};
      $script
      const blob = new Blob([${jsonEncode(jsonEncode(data))}], {type: 'application/json'});
      const url = URL.createObjectURL(blob);
      const link = new HTMLAnchorElement(); link.href = url; link.download = 'kascoven-time_lock-test.json';
      link.click(); URL.revokeObjectURL(url);
      const blocked = new HTMLAnchorElement(); blocked.href = 'https://evil.example/app.apk'; blocked.download = 'app.apk'; blocked.click();
      await new Promise(r => setTimeout(r, 20));
      console.log(JSON.stringify({messages, normalClicks}));
    '''
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final output = jsonDecode(result.stdout as String) as Map;
    expect(output['normalClicks'], 0);
    final exported = (output['messages'] as List).single as Map;
    expect(exported['capability'], 'unguessable-navigation-capability');
    expect(jsonDecode(exported['json'] as String), data);
  });
}
