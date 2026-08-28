import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wallet_snapshot.dart';
import '../services/activity_store.dart';
import '../services/kaspa_api.dart';
import '../services/native_security.dart';
import '../theme.dart';

class TangemRescueScreen extends StatefulWidget {
  const TangemRescueScreen({super.key});

  @override
  State<TangemRescueScreen> createState() => _TangemRescueScreenState();
}

class _TangemRescueScreenState extends State<TangemRescueScreen> {
  static const _pendingKey = 'kaspire_tangem_krc721_rescue_pending_v1';

  final _security = NativeSecurity();
  final _api = KaspaApi();
  final _recipient = TextEditingController();

  Map<String, Object?>? _card;
  WalletSnapshot? _wallet;
  WalletAsset? _collection;
  WalletNft? _nft;
  List<WalletNft> _nfts = const [];
  Map<String, Object?>? _pending;
  Map<String, Object?>? _receipt;
  Map<String, Object?>? _diagnostic;
  bool _working = false;
  String? _status;
  String? _error;

  String? get _address => _card?['address']?.toString();
  String? get _publicKey => _card?['publicKeyHex']?.toString();

  @override
  void initState() {
    super.initState();
    _loadDiagnostic();
  }

  Future<void> _loadDiagnostic() async {
    try {
      final diagnostic = await _security.getTangemDiagnostic();
      if (mounted) setState(() => _diagnostic = diagnostic);
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_security.cancelTangemSession());
    _recipient.dispose();
    super.dispose();
  }

  Future<void> _scanCard() async {
    setState(() {
      _working = true;
      _status = 'Hold the Tangem card against this phone…';
      _error = null;
      _receipt = null;
    });
    try {
      final card = await _security.scanTangemKaspa();
      final address = card['address']!.toString();
      if (mounted) {
        setState(() {
          _card = card;
          _status = 'Loading KRC-721 holdings for the Tangem address…';
        });
      }
      final results = await Future.wait<Object?>([
        _api.loadWallet(address),
        SharedPreferences.getInstance(),
      ]);
      final wallet = results[0] as WalletSnapshot;
      final prefs = results[1] as SharedPreferences;
      final pendingRaw = prefs.getString(_pendingKey);
      final pending = pendingRaw == null
          ? null
          : (jsonDecode(pendingRaw) as Map).cast<String, Object?>();
      final matchingPending =
          pending?['sender']?.toString().toLowerCase() == address.toLowerCase()
              ? pending
              : null;
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _collection = wallet.krc721Collections.firstOrNull;
        _pending = matchingPending;
        _working = false;
        _status = null;
      });
      if (_collection != null) await _loadCollection(_collection!);
    } on PlatformException catch (error) {
      _fail(error.message ?? 'Tangem NFC scan failed.');
      await _loadDiagnostic();
    } catch (error) {
      _fail('$error');
      await _loadDiagnostic();
    }
  }

  Future<void> _loadCollection(WalletAsset collection) async {
    final address = _address;
    if (address == null) return;
    setState(() {
      _working = true;
      _status = 'Loading ${collection.symbol} NFTs…';
      _collection = collection;
      _nft = null;
      _nfts = const [];
      _error = null;
    });
    try {
      final nfts = <WalletNft>[];
      int? offset = 0;
      while (offset != null && nfts.length < 1000) {
        final page = await _api.loadNftCollection(
          address,
          collection.symbol,
          offset: offset,
        );
        nfts.addAll(page.nfts);
        offset = page.nextOffset;
      }
      if (!mounted) return;
      setState(() {
        _nfts = nfts;
        _nft = nfts.firstOrNull;
        _working = false;
        _status = null;
      });
    } catch (error) {
      _fail('$error');
    }
  }

  Future<void> _rescue() async {
    final address = _address;
    final publicKey = _publicKey;
    final nft = _nft;
    if (address == null || publicKey == null || nft == null) return;
    setState(() {
      _working = true;
      _status = 'Preparing a locally verified KRC-721 commit…';
      _error = null;
      _receipt = null;
    });
    try {
      final recipient = await _api.resolveWalletInput(_recipient.text);
      final operation = <String, Object?>{
        'kind': 'krc721',
        'sender': address,
        'recipient': recipient,
        'ticker': nft.ticker,
        'amount': '',
        'tokenId': nft.tokenId,
        'assetId': '',
      };
      final inputs = await Future.wait<Object?>([
        _api.loadUtxos(address),
        _api.loadFeeRate(),
      ]);
      final request = <String, Object?>{
        'operation': operation,
        'publicKeyHex': publicKey,
        'feeRate': inputs[1] as double,
        'utxosJson': inputs[0] as String,
      };
      final prepared = await _security.prepareTangemCommit(request);
      final transaction =
          (prepared['transaction'] as Map).cast<String, Object?>();
      if (!mounted) return;
      final approved = await _confirm(
        title: 'Review Tangem rescue commit',
        rows: {
          'Asset': '${nft.ticker} #${nft.tokenId}',
          'From Tangem': address,
          'Final recipient': recipient,
          'Commit amount': _kas(transaction['amountSompi']),
          'Commit fee': _kas(transaction['feeSompi']),
          'Inputs': '${transaction['inputCount']}',
          'Signature': 'ECDSA · Tangem NFC',
        },
        warning:
            'The card cannot display Kaspa transaction fields. Verify this Kaspire review before tapping the card.',
      );
      if (!approved) throw StateError('Tangem rescue cancelled.');
      setState(() => _status = 'Tap the Tangem card to sign the commit…');
      final signatures = await _security.signTangemHashes(
        (prepared['hashes'] as List).cast<String>(),
        address,
      );
      final signed = await _security.finalizeTangemCommit(
        request,
        transaction['reviewHash']!.toString(),
        signatures,
      );
      final expectedId = signed['transactionId']!.toString();
      final acceptedId = await _api.broadcast(signed['submitJson']!.toString());
      if (acceptedId.isNotEmpty && acceptedId != expectedId) {
        throw StateError('Kaspa broadcaster returned a mismatching commit ID.');
      }
      final pending = <String, Object?>{
        'sender': address,
        'publicKeyHex': publicKey,
        'operation': operation,
        'plan': prepared['plan'],
        'commitTransactionId': expectedId,
        'commitFeeSompi': transaction['feeSompi'],
        'createdAt': DateTime.now().toIso8601String(),
        'state': 'commit-accepted',
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(pending));
      if (mounted) setState(() => _pending = pending);
      await _finishReveal(pending);
    } catch (error) {
      _fail(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _finishReveal(Map<String, Object?> pending) async {
    final address = _address;
    final publicKey = _publicKey;
    if (address == null || publicKey == null) {
      _fail('Scan the Tangem card again before resuming the reveal.');
      return;
    }
    if (pending['sender']?.toString().toLowerCase() != address.toLowerCase() ||
        pending['publicKeyHex']?.toString().toLowerCase() !=
            publicKey.toLowerCase()) {
      _fail('The scanned Tangem card does not match the pending rescue.');
      return;
    }
    setState(() {
      _working = true;
      _status = 'Waiting for the commit output to become spendable…';
      _error = null;
    });
    try {
      final plan = (pending['plan'] as Map).cast<String, Object?>();
      String? commitUtxos;
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          final raw = await _api.loadUtxos(plan['commitAddress']!.toString());
          final rows = jsonDecode(raw) as List;
          if (rows.any((row) =>
              (row as Map)['outpoint']?['transactionId'] ==
              pending['commitTransactionId'])) {
            commitUtxos = raw;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (commitUtxos == null) {
        throw StateError(
          'Commit is saved but is not spendable yet. Use Resume reveal in a moment.',
        );
      }
      final reveal = <String, Object?>{
        'operation': pending['operation'],
        'commitTransactionId': pending['commitTransactionId'],
        'commitUtxosJson': commitUtxos,
        'feeRate': await _api.loadFeeRate(),
      };
      final request = <String, Object?>{
        'reveal': reveal,
        'publicKeyHex': publicKey,
      };
      final prepared = await _security.prepareTangemReveal(request);
      final transaction =
          (prepared['transaction'] as Map).cast<String, Object?>();
      final operation = (pending['operation'] as Map).cast<String, Object?>();
      if (!mounted) return;
      final approved = await _confirm(
        title: 'Review Tangem rescue reveal',
        rows: {
          'Asset': '${operation['ticker']} #${operation['tokenId']}',
          'From Tangem': address,
          'Recipient': operation['recipient']!.toString(),
          'Reveal fee': _kas(transaction['feeSompi']),
          'Return to Tangem': _kas(transaction['returnSompi']),
          'Signature': 'ECDSA · Tangem NFC',
        },
        warning:
            'This reveal transfers the selected NFT. Verify the recipient before tapping the card.',
      );
      if (!approved) throw StateError('Reveal authorization cancelled.');
      setState(() => _status = 'Tap the Tangem card to sign the reveal…');
      final signatures = await _security.signTangemHashes(
        (prepared['hashes'] as List).cast<String>(),
        address,
      );
      final signed = await _security.finalizeTangemReveal(
        request,
        transaction['reviewHash']!.toString(),
        signatures,
      );
      final expectedId = signed['transactionId']!.toString();
      final acceptedId = await _api.broadcast(signed['submitJson']!.toString());
      if (acceptedId.isNotEmpty && acceptedId != expectedId) {
        throw StateError('Kaspa broadcaster returned a mismatching reveal ID.');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingKey);
      await ActivityStore().recordAssetTransfer(
        wallet: address,
        operation: operation,
        transactionId: expectedId,
        timestamp: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _pending = null;
        _working = false;
        _status = null;
        _receipt = {
          'commitTransactionId': pending['commitTransactionId'],
          'revealTransactionId': expectedId,
          'recipient': operation['recipient'],
        };
      });
    } catch (error) {
      final message = error.toString().replaceFirst('Bad state: ', '');
      final updated = <String, Object?>{
        ...pending,
        'state': 'reveal-pending',
        'lastError': message,
        'lastAttemptAt': DateTime.now().toIso8601String(),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(updated));
      if (mounted) setState(() => _pending = updated);
      _fail(message);
    }
  }

  Future<bool> _confirm({
    required String title,
    required Map<String, String> rows,
    required String warning,
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...rows.entries.map(
                    (row) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.key,
                            style: const TextStyle(
                              color: KasVaultTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 3),
                          SelectableText(
                            row.value,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB65C).withValues(alpha: 0.1),
                      border: Border.all(color: const Color(0xFFFFB65C)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(warning),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.nfc_rounded),
                label: const Text('Sign with Tangem'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _working = false;
      _status = null;
      _error = message;
    });
  }

  String _kas(Object? sompi) {
    final value = (sompi as num?)?.toInt() ?? int.tryParse('$sompi') ?? 0;
    return '${(value / 100000000).toStringAsFixed(8)} KAS';
  }

  @override
  Widget build(BuildContext context) {
    final collections = _wallet?.krc721Collections ?? const <WalletAsset>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Tangem Rescue')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.health_and_safety_outlined),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'KRC-721 recovery from a Tangem Kaspa address',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Kaspire builds and validates a typed commit/reveal transfer. The Tangem card signs only the exact Kaspa ECDSA hashes. Its private key never enters Kaspire.',
                    style: TextStyle(color: KasVaultTheme.muted),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'How to use Tangem Rescue:',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Tap Scan Tangem card.\n'
                    '2. Hold the card against this smartphone and keep it there for the entire transaction.\n'
                    '3. Select the NFT below, then review and confirm both the commit and reveal steps.\n\n'
                    'If the Tangem app opens in the foreground when the card is presented, use another smartphone or temporarily uninstall the Tangem app while completing the rescue.',
                    style: TextStyle(color: KasVaultTheme.muted, height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _working ? null : _scanCard,
                    icon: const Icon(Icons.nfc_rounded),
                    label:
                        Text(_card == null ? 'Scan Tangem card' : 'Scan again'),
                  ),
                ],
              ),
            ),
            if (_diagnostic != null &&
                _diagnostic!['stage']?.toString() != 'not-started' &&
                _diagnostic!['stage']?.toString() != 'scan-complete') ...[
              const SizedBox(height: 14),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tangem NFC diagnostic',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      'Stage: ${_diagnostic!['stage']}\n${(_diagnostic!['crash']?.toString().isNotEmpty ?? false) ? _diagnostic!['crash'] : 'No native exception was recorded.'}',
                      style: const TextStyle(
                        color: KasVaultTheme.muted,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: jsonEncode(_diagnostic)),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Tangem diagnostic copied'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy diagnostic'),
                    ),
                  ],
                ),
              ),
            ],
            if (_card != null) ...[
              const SizedBox(height: 14),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Verified card address',
                      style: TextStyle(
                        color: KasVaultTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _address!,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "${_card!['derivationPath']} · card …${_card!['cardIdSuffix']}",
                      style: const TextStyle(color: KasVaultTheme.muted),
                    ),
                    if (_card!['attestationWarning'].toString().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _card!['attestationWarning'].toString(),
                        style: const TextStyle(
                          color: Color(0xFFFFB65C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (_pending != null) ...[
              const SizedBox(height: 14),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pending reveal',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _pending!['commitTransactionId']!.toString(),
                      style: const TextStyle(color: KasVaultTheme.muted),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed:
                          _working ? null : () => _finishReveal(_pending!),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Resume reveal'),
                    ),
                  ],
                ),
              ),
            ],
            if (_card != null && _pending == null) ...[
              const SizedBox(height: 18),
              DropdownButtonFormField<WalletAsset>(
                initialValue: _collection,
                decoration:
                    const InputDecoration(labelText: 'KRC-721 collection'),
                items: collections
                    .map(
                      (collection) => DropdownMenuItem(
                        value: collection,
                        child: Text(collection.symbol.toUpperCase()),
                      ),
                    )
                    .toList(),
                onChanged: _working
                    ? null
                    : (value) {
                        if (value != null) _loadCollection(value);
                      },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<WalletNft>(
                initialValue: _nft,
                decoration: const InputDecoration(labelText: 'NFT token ID'),
                items: _nfts
                    .map(
                      (nft) => DropdownMenuItem(
                        value: nft,
                        child: Text('${nft.ticker} #${nft.tokenId}'),
                      ),
                    )
                    .toList(),
                onChanged:
                    _working ? null : (value) => setState(() => _nft = value),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _recipient,
                enabled: !_working,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Recipient address / KNS name',
                  hintText: 'kaspa:…',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: !_working && _nft != null ? _rescue : null,
                icon: const Icon(Icons.outbox_rounded),
                label: const Text('Review rescue transfer'),
              ),
            ],
            if (_working) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(),
              if (_status != null) ...[
                const SizedBox(height: 10),
                Text(_status!, textAlign: TextAlign.center),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFF6B75)),
              ),
            ],
            if (_receipt != null) ...[
              const SizedBox(height: 16),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Rescue transfer submitted',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    const Text('Commit transaction'),
                    SelectableText(_receipt!['commitTransactionId'].toString()),
                    const SizedBox(height: 10),
                    const Text('Reveal transaction'),
                    SelectableText(_receipt!['revealTransactionId'].toString()),
                  ],
                ),
              ),
            ],
            if (_card != null && !_working && collections.isEmpty) ...[
              const SizedBox(height: 18),
              const Text(
                'No KRC-721 holdings were returned for this Tangem address.',
                style: TextStyle(color: KasVaultTheme.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          border: Border.all(color: KasVaultTheme.line),
          borderRadius: BorderRadius.circular(18),
        ),
        child: child,
      );
}
