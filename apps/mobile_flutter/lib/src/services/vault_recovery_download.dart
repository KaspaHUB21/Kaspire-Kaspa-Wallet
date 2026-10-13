import 'dart:convert';

import 'dapp_browser_policy.dart';

/// Narrow public-metadata export, not a general WebView download capability.
class VaultRecoveryDownload {
  const VaultRecoveryDownload(this.fileName, this.json);
  final String fileName;
  final String json;
  static const maxBytes = 512 * 1024;
  static bool allowedOrigin(Uri uri) =>
      DappBrowserPolicy.approvedPage(uri) && uri.host == 'vaults.kaslab.space';

  static VaultRecoveryDownload parse(String message) {
    if (message.length > maxBytes + 8192) {
      throw const FormatException('Recovery file is too large.');
    }
    final envelope = jsonDecode(message);
    if (envelope is! Map ||
        envelope['filename'] is! String ||
        envelope['json'] is! String) {
      throw const FormatException('Invalid recovery export.');
    }
    final name = envelope['filename'] as String,
        json = envelope['json'] as String;
    if (!RegExp(r'^kascoven-(time_lock|dead_man_switch)-[a-z0-9-]{1,160}\.json$')
            .hasMatch(name) ||
        utf8.encode(json).length > maxBytes) {
      throw const FormatException('Unsupported recovery filename or size.');
    }
    final data = jsonDecode(json);
    if (data is! Map ||
        data['protocol'] != 'kascoven-vault-recovery-v1' ||
        data['network'] != 'kaspa-mainnet' ||
        !['time_lock', 'dead_man_switch'].contains(data['type']) ||
        !name.startsWith('kascoven-${data['type']}-') ||
        !RegExp(r'^kaspa:[a-z0-9]{40,80}$')
            .hasMatch('${data['vaultAddress']}') ||
        !RegExp(r'^[a-fA-F0-9]+$').hasMatch('${data['redeemScript']}')) {
      throw const FormatException(
          'This is not a supported Vault recovery file.');
    }
    const fields = {
      'protocol',
      'network',
      'exportedAtIso',
      'vaultProtocol',
      'payloadVersion',
      'type',
      'vaultName',
      'deployTxId',
      'selectedOutpoint',
      'selectedOutpointId',
      'vaultAddress',
      'ownerAddress',
      'beneficiaryAddress',
      'ownerPublicKey',
      'unlockTime',
      'inactivityDaaBlocks',
      'lockDaaBlocks',
      'lockSeconds',
      'lockAmountSompi',
      'lockAmountKas',
      'redeemScript',
      'scriptPublicKey',
      'createdBlueScore',
      'createdAtIso',
      'lastPulseBlueScore',
      'lastPulseTxId',
      'rawPayload'
    };
    if (data.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unsupported recovery fields.');
    }
    void rejectSecrets(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (RegExp(r'(mnemonic|seed|private.?key|password|secret)',
                  caseSensitive: false)
              .hasMatch('${entry.key}')) {
            throw const FormatException(
                'Recovery export must not contain wallet secrets.');
          }
          rejectSecrets(entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          rejectSecrets(item);
        }
      }
    }

    rejectSecrets(data);
    return VaultRecoveryDownload(name, json);
  }

  /// Installed only in the main frame of the exact approved Vault origin.
  /// A per-navigation random capability prevents foreign frames from invoking
  /// the export channel. Blob contents are read before the page revokes them.
  static String script(String capability) => '''
    (() => {
      if (window.top !== window || location.origin !== 'https://vaults.kaslab.space' || window.__kaspireVaultExport) return;
      window.__kaspireVaultExport = true;
      const capability = ${jsonEncode(capability)};
      const blobs = new Map(), create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
      URL.createObjectURL = blob => {
        const url = create(blob);
        if (blob instanceof Blob && blob.type === 'application/json' && blob.size <= $maxBytes) {
          if (blobs.size >= 20) blobs.delete(blobs.keys().next().value);
          blobs.set(url, blob);
        }
        return url;
      };
      URL.revokeObjectURL = url => { blobs.delete(url); revoke(url); };
      function exportAnchor(anchor) {
        if (!anchor.download) return false;
        const blob = blobs.get(anchor.href);
        if (blob && /^kascoven-(time_lock|dead_man_switch)-[a-z0-9-]{1,160}\\.json\$/.test(anchor.download)) {
          const filename = anchor.download;
          blob.text().then(json => KaspireVaultRecovery.postMessage(JSON.stringify({capability, filename, json}))).catch(() => {});
        }
        return true; // Other downloads stay blocked.
      }
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function() { if (!exportAnchor(this)) return click.call(this); };
      document.addEventListener('click', event => {
        const anchor = event.target.closest?.('a[download]');
        if (anchor && exportAnchor(anchor)) { event.preventDefault(); event.stopImmediatePropagation(); }
      }, true);
    })();
  ''';
}
