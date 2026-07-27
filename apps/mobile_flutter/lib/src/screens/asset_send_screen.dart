import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/asset_send_intent.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kaspa_api.dart';
import '../services/activity_store.dart';
import '../services/native_security.dart';
import '../services/signer_service.dart';
import '../theme.dart';

enum _AssetKind { krc20, kcc20, krc721, kns }

class AssetSendScreen extends StatefulWidget {
  const AssetSendScreen({
    super.key,
    required this.address,
    required this.onDone,
    this.initialAsset,
  });
  final String address;
  final VoidCallback onDone;
  final AssetSendIntent? initialAsset;
  @override
  State<AssetSendScreen> createState() => _AssetSendScreenState();
}

class _AssetSendScreenState extends State<AssetSendScreen> {
  String get _pendingKey =>
      'kaspire_pending_inscription_v2_${widget.address.toLowerCase()}';
  final _api = KaspaApi();
  final _security = NativeSecurity();
  final _signer = SignerService();
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  WalletSnapshot? _wallet;
  _AssetKind _kind = _AssetKind.krc20;
  WalletAsset? _token;
  WalletAsset? _covenantToken;
  WalletAsset? _collection;
  WalletNft? _nft;
  KnsDomain? _domain;
  List<WalletNft> _nfts = const [];
  Map<String, Object?>? _operation;
  Map<String, Object?>? _plan;
  PreparedPayment? _commit;
  Map<String, Object?>? _receipt;
  Map<String, Object?>? _kcc20Request;
  Map<String, Object?>? _kcc20Review;
  Map<String, Object?>? _pending;
  String? _error;
  String? _status;
  bool _working = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingRaw = prefs.getString(_pendingKey);
      final wallet = await _api.loadWallet(widget.address);
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        final intent = widget.initialAsset;
        _kind = intent?.kind == 'krc721'
            ? _AssetKind.krc721
            : intent?.kind == 'kcc20'
                ? _AssetKind.kcc20
                : intent?.kind == 'kns'
                    ? _AssetKind.kns
                    : _AssetKind.krc20;
        _token = wallet.krc20Tokens
                .where((asset) =>
                    asset.symbol.toLowerCase() == intent?.symbol?.toLowerCase())
                .firstOrNull ??
            wallet.krc20Tokens.firstOrNull;
        _covenantToken = wallet.kcc20Tokens
                .where((asset) =>
                    asset.covenantId == intent?.assetId ||
                    asset.symbol.toLowerCase() == intent?.symbol?.toLowerCase())
                .firstOrNull ??
            wallet.kcc20Tokens.firstOrNull;
        _collection = wallet.krc721Collections
                .where((asset) =>
                    asset.symbol.toLowerCase() == intent?.symbol?.toLowerCase())
                .firstOrNull ??
            wallet.krc721Collections.firstOrNull;
        _domain = wallet.knsDomains
                .where((domain) =>
                    domain.assetId == intent?.assetId ||
                    domain.name.toLowerCase() ==
                        intent?.domainName?.toLowerCase())
                .firstOrNull ??
            wallet.knsDomains.firstOrNull;
        _pending = pendingRaw == null
            ? null
            : (jsonDecode(pendingRaw) as Map).cast<String, Object?>();
        _working = false;
      });
      if (_collection != null) await _loadNfts(_collection!);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = '$e';
        });
      }
    }
  }

  void _resetAfterReceipt({required bool returnToWallet}) {
    _recipient.clear();
    _amount.clear();
    setState(() {
      _wallet = null;
      _token = null;
      _covenantToken = null;
      _collection = null;
      _nft = null;
      _domain = null;
      _nfts = const [];
      _operation = null;
      _plan = null;
      _commit = null;
      _receipt = null;
      _kcc20Request = null;
      _kcc20Review = null;
      _pending = null;
      _error = null;
      _status = null;
      _working = true;
    });
    _load();
    if (returnToWallet) widget.onDone();
  }

  Future<void> _loadNfts(WalletAsset collection) async {
    setState(() {
      _collection = collection;
      _nfts = const [];
      _nft = null;
    });
    try {
      final all = <WalletNft>[];
      int? offset = 0;
      while (offset != null && all.length < 1000) {
        final page = await _api.loadNftCollection(
            widget.address, collection.symbol,
            offset: offset);
        all.addAll(page.nfts);
        offset = page.nextOffset;
      }
      if (mounted) {
        setState(() {
          _nfts = all;
          _nft = all
                  .where((nft) => nft.tokenId == widget.initialAsset?.tokenId)
                  .firstOrNull ??
              all.firstOrNull;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String? _rawTokenAmount(WalletAsset token, String input) {
    final normalized = input.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(normalized)) return null;
    final parts = normalized.split('.');
    if (parts.length == 2 && parts[1].length > token.decimals) return null;
    final fraction = parts.length == 2
        ? parts[1].padRight(token.decimals, '0')
        : ''.padRight(token.decimals, '0');
    final raw = BigInt.tryParse('${parts[0]}$fraction');
    if (raw == null || raw <= BigInt.zero) return null;
    final available = BigInt.tryParse(token.rawBalance ?? '');
    if (available != null && raw > available) return null;
    return raw.toString();
  }

  Future<void> _prepare() async {
    setState(() {
      _working = true;
      _error = null;
      _receipt = null;
    });
    try {
      if (!await _security.hasNativeWalletFor(widget.address)) {
        throw StateError('This is a watch-only wallet.');
      }
      final recipient = await _api.resolveWalletInput(_recipient.text);
      final operation = <String, Object?>{
        'kind': _kind.name,
        'sender': widget.address,
        'recipient': recipient,
        'ticker': '',
        'amount': '',
        'tokenId': '',
        'assetId': '',
      };
      switch (_kind) {
        case _AssetKind.krc20:
          final token = _token;
          if (token == null) throw StateError('Select a KRC-20 token.');
          final raw = _rawTokenAmount(token, _amount.text);
          if (raw == null) {
            throw StateError(
                'Invalid amount, too many decimals, or insufficient token balance.');
          }
          operation['ticker'] = token.symbol;
          operation['amount'] = raw;
          operation['displayAmount'] = _amount.text.trim();
          break;
        case _AssetKind.kcc20:
          final token = _covenantToken;
          if (token == null) throw StateError('Select a KCC20 token.');
          if (token.validationStatus != 'verified') {
            throw StateError('Only indexer-verified KCC20 tokens can be sent.');
          }
          if (!token.discoveryComplete || token.kcc20Cells.isEmpty) {
            throw StateError(
                'KCC20 cell discovery is incomplete. Refresh and verify the token before sending.');
          }
          final raw = _rawTokenAmount(token, _amount.text);
          if (raw == null) {
            throw StateError(
                'Invalid amount, too many decimals, or insufficient token balance.');
          }
          final fundingUtxos = await _api.loadUtxos(widget.address);
          final request = <String, Object?>{
            'sender': widget.address,
            'recipient': recipient,
            'covenantId': token.covenantId,
            'ticker': token.symbol,
            'amount': int.parse(raw),
            'decimals': token.decimals,
            'feeRate': 100.0,
            'templateHash': token.templateHash,
            'cells': token.kcc20Cells.map((cell) => cell.toJson()).toList(),
            'fundingUtxosJson': fundingUtxos,
          };
          final review = await _security.prepareKcc20Transfer(request);
          operation['ticker'] = token.symbol;
          operation['amount'] = raw;
          operation['displayAmount'] = _amount.text.trim();
          operation['covenantId'] = token.covenantId;
          if (mounted) {
            setState(() {
              _operation = operation;
              _kcc20Request = request;
              _kcc20Review = review;
              _working = false;
            });
          }
          return;
        case _AssetKind.krc721:
          if (_nft == null) throw StateError('Select an NFT.');
          operation['ticker'] = _nft!.ticker;
          operation['tokenId'] = _nft!.tokenId;
          break;
        case _AssetKind.kns:
          if (_domain?.assetId == null || _domain!.assetId!.isEmpty) {
            throw StateError(
                'The KNS indexer did not provide this domain asset ID. Refresh and try again.');
          }
          operation['assetId'] = _domain!.assetId!;
          operation['domainName'] = _domain!.name;
          break;
      }
      final plan = await _security.prepareInscription(operation);
      final results = await Future.wait(
          [_api.loadUtxos(widget.address), _api.loadFeeRate()]);
      final commit = await _signer.prepare(
          sender: widget.address,
          recipient: plan['commitAddress']! as String,
          amountSompi: (plan['commitAmountSompi'] as num).toInt(),
          feeRate: results[1] as double,
          utxosJson: results[0] as String);
      if (mounted) {
        setState(() {
          _operation = operation;
          _plan = plan;
          _commit = commit;
          _working = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _signAndBroadcastKcc20() async {
    final request = _kcc20Request!;
    final review = _kcc20Review!;
    final operation = _operation!;
    setState(() {
      _working = true;
      _error = null;
      _status = 'Authorizing KCC20 covenant transfer…';
    });
    try {
      final signed = await _security.signKcc20Transfer(
        request,
        review['reviewHash']! as String,
      );
      if (mounted) {
        setState(
            () => _status = 'Transaction signed. Sending to Kaspa mainnet…');
      }
      final expectedTransactionId = signed['transactionId']! as String;
      final transactionId = await _api.broadcastKcc20(
        signed['wrpcJson']! as String,
        expectedTransactionId: expectedTransactionId,
      );
      if (transactionId.isEmpty) {
        throw StateError('Broadcast was accepted without a transaction ID.');
      }
      await ActivityStore().recordAssetTransfer(
        wallet: widget.address,
        operation: operation,
        transactionId: transactionId,
        timestamp: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _working = false;
        _status = null;
        _kcc20Request = null;
        _kcc20Review = null;
        _receipt = <String, Object?>{
          'operation': operation,
          'recipient': operation['recipient'],
          'revealTransactionId': transactionId,
          'revealFeeSompi': review['feeSompi'],
          'kcc20': true,
          'mass': review['mass'],
          'templateHash': review['templateHash'],
        };
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _status = null;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _commitAndReveal() async {
    final operation = _operation!;
    final plan = _plan!;
    final commit = _commit!;
    setState(() {
      _working = true;
      _error = null;
      _status = 'Authorizing commit transaction…';
    });
    try {
      final signed = await _signer.sign(commit);
      await _api.broadcast(signed.submitJson);
      final pending = <String, Object?>{
        'operation': operation,
        'plan': plan,
        'commitTransactionId': signed.transactionId,
        'commitFeeSompi': commit.feeSompi,
        'createdAt': DateTime.now().toIso8601String(),
        'state': 'commit-accepted'
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(pending));
      if (mounted) {
        setState(() {
          _pending = pending;
          _operation = null;
          _plan = null;
          _commit = null;
          _status = 'Commit accepted. Waiting for its spendable output…';
        });
      }
      await _finishPending(pending);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _status = null;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _finishPending(Map<String, Object?> pending) async {
    setState(() {
      _working = true;
      _error = null;
      _status = 'Looking for the committed output…';
    });
    try {
      final plan = (pending['plan'] as Map).cast<String, Object?>();
      String? utxos;
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          utxos = await _api.loadUtxos(plan['commitAddress']! as String);
          final rows = jsonDecode(utxos) as List;
          if (rows.any((e) =>
              (e as Map)['outpoint']?['transactionId'] ==
              pending['commitTransactionId'])) {
            break;
          }
          utxos = null;
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (utxos == null) {
        throw StateError(
            'Commit is saved, but not spendable yet. Tap RESUME REVEAL in a moment.');
      }
      final feeRate = await _api.loadFeeRate();
      final revealRequest = <String, Object?>{
        'operation': pending['operation'],
        'commitTransactionId': pending['commitTransactionId'],
        'commitUtxosJson': utxos,
        'feeRate': feeRate
      };
      final review = await _security.prepareReveal(revealRequest);
      if (mounted) {
        setState(() =>
            _status = 'Commit found. Authorize the final reveal transaction…');
      }
      if (!mounted) return;
      final signed = await _security.signReveal(
          revealRequest, review['reviewHash']! as String);
      await _api.broadcast(signed['submitJson']! as String);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingKey);
      final completedAt = DateTime.now();
      await ActivityStore().recordAssetTransfer(
        wallet: widget.address,
        operation: pending['operation'] as Map,
        transactionId: signed['transactionId']! as String,
        timestamp: completedAt,
      );
      if (!mounted) return;
      setState(() {
        _pending = null;
        _working = false;
        _status = null;
        _receipt = <String, Object?>{
          ...pending,
          'recipient': (pending['operation'] as Map)['recipient'],
          'revealTransactionId': signed['transactionId'],
          'revealFeeSompi': review['feeSompi'],
          'completedAt': completedAt.toIso8601String()
        };
      });
    } catch (e) {
      final message = e.toString().replaceFirst('Bad state: ', '');
      final updated = <String, Object?>{
        ...pending,
        'state': message.contains('not spendable')
            ? 'waiting-for-commit'
            : message.contains('cancelled')
                ? 'authorization-cancelled'
                : 'reveal-failed',
        'lastError': message,
        'lastAttemptAt': DateTime.now().toIso8601String(),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(updated));
      if (mounted) {
        setState(() {
          _pending = updated;
          _working = false;
          _status = null;
          _error = message;
        });
      }
    }
  }

  String _assetBalance(WalletAsset asset) {
    final raw = BigInt.tryParse(asset.rawBalance ?? '');
    if (raw != null) return formatRawTokenAmount(raw, asset.decimals);
    return formatEnglishNumber(asset.balance, trimTrailingZeros: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_receipt != null) {
      return _AssetReceipt(
        data: _receipt!,
        onSendAnother: () => _resetAfterReceipt(returnToWallet: false),
        onDone: () => _resetAfterReceipt(returnToWallet: true),
      );
    }
    final pending = _pending;
    if (pending != null) {
      return _PendingView(
          data: pending,
          working: _working,
          status: _status,
          error: _error,
          onResume: () => _finishPending(pending));
    }
    final commit = _commit;
    if (commit != null) {
      return _AssetReview(
          operation: _operation!,
          commit: commit,
          working: _working,
          status: _status,
          onCancel: () => setState(() {
                _commit = null;
                _operation = null;
                _plan = null;
              }),
          onConfirm: _commitAndReveal);
    }
    final covenantReview = _kcc20Review;
    if (covenantReview != null) {
      return _Kcc20Review(
        operation: _operation!,
        review: covenantReview,
        working: _working,
        status: _status,
        error: _error,
        onCancel: () => setState(() {
          _operation = null;
          _kcc20Request = null;
          _kcc20Review = null;
          _error = null;
        }),
        onConfirm: _signAndBroadcastKcc20,
      );
    }
    return SafeArea(
      top: false,
      child: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('SEND ASSET',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text(
            'KRC-20, KRC-721 and KNS use commit/reveal. KCC20 is signed locally and submitted directly to Kaspa mainnet.',
            style: TextStyle(color: KasVaultTheme.muted)),
        const SizedBox(height: 20),
        SegmentedButton<_AssetKind>(segments: const [
          ButtonSegment(value: _AssetKind.krc20, label: Text('KRC-20')),
          ButtonSegment(value: _AssetKind.kcc20, label: Text('KCC20')),
          ButtonSegment(value: _AssetKind.krc721, label: Text('KRC-721')),
          ButtonSegment(value: _AssetKind.kns, label: Text('KNS')),
        ], selected: {
          _kind
        }, onSelectionChanged: (v) => setState(() => _kind = v.first)),
        const SizedBox(height: 18),
        if (_working && _wallet == null)
          const Center(child: CircularProgressIndicator()),
        if (_kind == _AssetKind.krc20) ...[
          DropdownButtonFormField<WalletAsset>(
              initialValue: _token,
              isExpanded: true,
              isDense: false,
              itemHeight: 76,
              decoration: const InputDecoration(
                labelText: 'Token',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: EdgeInsets.fromLTRB(14, 18, 10, 10),
                constraints: BoxConstraints(minHeight: 86),
              ),
              items: (_wallet?.krc20Tokens ?? const [])
                  .map((a) => DropdownMenuItem(
                      value: a,
                      child: SizedBox(
                        height: 60,
                        width: double.infinity,
                        child: _Krc20TokenOption(
                          asset: a,
                          balance: _assetBalance(a),
                        ),
                      )))
                  .toList(),
              onChanged: (v) => setState(() => _token = v)),
          const SizedBox(height: 14),
          TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount')),
        ],
        if (_kind == _AssetKind.kcc20) ...[
          DropdownButtonFormField<WalletAsset>(
              initialValue: _covenantToken,
              isExpanded: true,
              isDense: false,
              itemHeight: 76,
              decoration: const InputDecoration(
                labelText: 'Verified token',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: EdgeInsets.fromLTRB(14, 18, 10, 10),
                constraints: BoxConstraints(minHeight: 86),
              ),
              items: (_wallet?.kcc20Tokens ?? const [])
                  .map((asset) => DropdownMenuItem(
                      value: asset,
                      child: SizedBox(
                        height: 60,
                        width: double.infinity,
                        child: _Krc20TokenOption(
                          asset: asset,
                          balance: _assetBalance(asset),
                        ),
                      )))
                  .toList(),
              onChanged: (value) => setState(() => _covenantToken = value)),
          const SizedBox(height: 10),
          if (_covenantToken != null)
            Text(
              _covenantToken!.discoveryComplete
                  ? 'Indexer verified · ${_covenantToken!.kcc20Cells.length} spendable cell(s)'
                  : 'Sending disabled: cell discovery is incomplete.',
              style: TextStyle(
                color: _covenantToken!.discoveryComplete
                    ? KasVaultTheme.mint
                    : const Color(0xFFFFB65C),
                fontSize: 12,
              ),
            ),
          const SizedBox(height: 14),
          TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount')),
        ],
        if (_kind == _AssetKind.krc721) ...[
          DropdownButtonFormField<WalletAsset>(
              initialValue: _collection,
              decoration: const InputDecoration(labelText: 'Collection'),
              items: (_wallet?.krc721Collections ?? const [])
                  .map((a) => DropdownMenuItem(value: a, child: Text(a.symbol)))
                  .toList(),
              onChanged: (v) {
                if (v != null) _loadNfts(v);
              }),
          const SizedBox(height: 14),
          DropdownButtonFormField<WalletNft>(
              key: ValueKey(_nft),
              initialValue: _nft,
              decoration: const InputDecoration(labelText: 'NFT'),
              items: _nfts
                  .map((n) => DropdownMenuItem(
                      value: n,
                      child: Text(
                          '${n.ticker} #${n.tokenId}${n.rarityRank == null ? '' : '  ·  Rank ${n.rarityRank}'}')))
                  .toList(),
              onChanged: (v) => setState(() => _nft = v)),
        ],
        if (_kind == _AssetKind.kns)
          DropdownButtonFormField<KnsDomain>(
              initialValue: _domain,
              decoration: const InputDecoration(labelText: 'Domain'),
              items: (_wallet?.knsDomains ?? const [])
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
                  .toList(),
              onChanged: (v) => setState(() => _domain = v)),
        const SizedBox(height: 14),
        TextField(
            controller: _recipient,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: 'Recipient', hintText: 'kaspa:q… or name.kas')),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!,
                  style: const TextStyle(color: Color(0xFFFF8A65)))),
        const SizedBox(height: 20),
        FilledButton.icon(
            onPressed: _working ? null : _prepare,
            icon: const Icon(Icons.shield_outlined),
            label: Text(_working ? 'PREPARING…' : 'REVIEW ASSET TRANSFER')),
      ]),
    );
  }
}

class _Krc20TokenOption extends StatelessWidget {
  const _Krc20TokenOption({required this.asset, required this.balance});

  final WalletAsset asset;
  final String balance;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF12302E),
      child: Center(
        child: Text(
          asset.symbol.isEmpty ? '?' : asset.symbol.substring(0, 1),
          style: const TextStyle(
            color: KasVaultTheme.mint,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    return Row(
      children: [
        SizedBox.square(
          dimension: 44,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: const Color(0xFF12302E),
              child: asset.imageUrl == null
                  ? fallback
                  : Padding(
                      padding: const EdgeInsets.all(3),
                      child: Image.network(
                        asset.imageUrl!,
                        width: 38,
                        height: 38,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => fallback,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                asset.symbol,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    balance,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                      color: KasVaultTheme.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Kcc20Review extends StatelessWidget {
  const _Kcc20Review({
    required this.operation,
    required this.review,
    required this.working,
    required this.status,
    required this.error,
    required this.onCancel,
    required this.onConfirm,
  });

  final Map<String, Object?> operation;
  final Map<String, Object?> review;
  final bool working;
  final String? status;
  final String? error;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'REVIEW KCC20 COVENANT TRANSFER',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            const Text(
              'The native core reconstructed every state script and will execute every input locally before sending the transaction to Kaspa mainnet.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
            const SizedBox(height: 8),
            const Text(
              'Toccata fees use fee mass (compute or normalized transient). Storage mass is shown separately as a hard capacity limit.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
            const SizedBox(height: 18),
            _Card(children: [
              const _Row('Validation', 'Indexer verified'),
              _Row('Token', operation['ticker'].toString()),
              _Row(
                'Amount',
                '${formatEnglishDecimal(operation['displayAmount'].toString())} ${operation['ticker']}',
              ),
              _Row('Recipient', operation['recipient'].toString()),
              _Row('Covenant ID', review['covenantId'].toString()),
              _Row('Template hash', review['templateHash'].toString()),
              _Row('Covenant inputs', review['covenantInputCount'].toString()),
              _Row(
                  'Covenant outputs', review['covenantOutputCount'].toString()),
              _Row('KAS in token inputs',
                  '${formatSompi((review['lockedKasSompi'] as num).toInt())} KAS'),
              if ((review['lockedKasTopUpSompi'] as num?)?.toInt() != 0)
                _Row('KAS reserve top-up',
                    '${formatSompi((review['lockedKasTopUpSompi'] as num).toInt())} KAS'),
              if ((review['lockedKasReleasedSompi'] as num?)?.toInt() != 0)
                _Row('KAS returned to wallet',
                    '${formatSompi((review['lockedKasReleasedSompi'] as num).toInt())} KAS'),
              _Row('KAS in new token cells',
                  '${formatSompi((review['lockedKasOutputSompi'] as num).toInt())} KAS'),
              _Row('Network fee',
                  '${formatSompi((review['feeSompi'] as num).toInt())} KAS'),
              _Row('Effective mass',
                  formatEnglishDecimal(review['mass'].toString())),
              _Row('Compute mass',
                  formatEnglishDecimal(review['computeMass'].toString())),
              _Row('Storage mass (normalized)',
                  formatEnglishDecimal(review['storageMass'].toString())),
              _Row('Safe storage target',
                  formatEnglishDecimal(review['storageMassTarget'].toString())),
              _Row('Transient mass (normalized)',
                  formatEnglishDecimal(review['transientMass'].toString())),
              _Row('Fee mass',
                  formatEnglishDecimal(review['feeMass'].toString())),
              _Row('Compute budget', review['computeBudget'].toString()),
            ]),
            if ((review['lockedKasTopUpSompi'] as num?)?.toInt() != 0)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'The reserve top-up adds only the KAS needed to keep the new token cells spendable. It is not a network fee.',
                  style: TextStyle(color: Color(0xFFFFC857)),
                ),
              ),
            if ((review['lockedKasReleasedSompi'] as num?)?.toInt() != 0)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Excess KAS from the consumed token cells returns as normal wallet change.',
                  style: TextStyle(color: KasVaultTheme.mint),
                ),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(status!,
                    style: const TextStyle(color: KasVaultTheme.mint)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(error!,
                    style: const TextStyle(color: Color(0xFFFF8A65))),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: working ? null : onConfirm,
              icon: const Icon(Icons.send_rounded),
              label: Text(working ? 'SENDING ON-CHAIN…' : 'SEND ON-CHAIN'),
            ),
            TextButton(
              onPressed: working ? null : onCancel,
              child: const Text('CANCEL'),
            ),
          ],
        ),
      );
}

class _AssetReview extends StatelessWidget {
  const _AssetReview(
      {required this.operation,
      required this.commit,
      required this.working,
      required this.status,
      required this.onCancel,
      required this.onConfirm});
  final Map<String, Object?> operation;
  final PreparedPayment commit;
  final bool working;
  final String? status;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  @override
  Widget build(BuildContext context) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('REVIEW ASSET TRANSFER',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
        const SizedBox(height: 18),
        _Card(children: [
          _Row('Protocol', operation['kind'].toString().toUpperCase()),
          _Row('Recipient', operation['recipient'].toString()),
          if (operation['ticker'].toString().isNotEmpty)
            _Row('Ticker', operation['ticker'].toString()),
          if (operation['amount'].toString().isNotEmpty)
            _Row('Raw amount',
                formatEnglishDecimal(operation['amount'].toString())),
          if (operation['displayAmount']?.toString().isNotEmpty == true)
            _Row('Amount',
                '${formatEnglishDecimal(operation['displayAmount'].toString())} ${operation['ticker']}'),
          if (operation['tokenId'].toString().isNotEmpty)
            _Row('Token ID', operation['tokenId'].toString()),
          _Row('Temporary commit', '0.30000000 KAS'),
          _Row(
              'Commit network fee', '${formatEnglishNumber(commit.feeKas)} KAS')
        ]),
        const SizedBox(height: 14),
        const Text(
            'The 0.3 KAS commit is returned to your wallet by the reveal transaction, minus its network fee. A saved pending transfer can be resumed.',
            style: TextStyle(color: KasVaultTheme.muted)),
        if (status != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(status!,
                  style: const TextStyle(color: KasVaultTheme.mint))),
        const SizedBox(height: 20),
        FilledButton(
            onPressed: working ? null : onConfirm,
            child: Text(working ? 'WORKING…' : 'AUTHORIZE COMMIT + REVEAL')),
        TextButton(
            onPressed: working ? null : onCancel, child: const Text('CANCEL')),
      ]));
}

class _PendingView extends StatelessWidget {
  const _PendingView(
      {required this.data,
      required this.working,
      required this.status,
      required this.error,
      required this.onResume});
  final Map<String, Object?> data;
  final bool working;
  final String? status;
  final String? error;
  final VoidCallback onResume;
  @override
  Widget build(BuildContext context) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(Icons.sync_rounded, size: 58, color: KasVaultTheme.mint),
        const SizedBox(height: 15),
        const Text('TRANSFER COMMIT SAVED',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 16),
        _Card(children: [
          _Row('Commit TX', data['commitTransactionId'].toString()),
          _Row(
            'State',
            (data['state'] ?? 'reveal-pending').toString().replaceAll('-', ' '),
          ),
          if (data['lastError'] != null)
            _Row('Last attempt', data['lastError'].toString()),
        ]),
        if (status != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(status!, textAlign: TextAlign.center)),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(error!,
                  style: const TextStyle(color: Color(0xFFFF8A65)))),
        const SizedBox(height: 20),
        FilledButton.icon(
            onPressed: working ? null : onResume,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(working ? 'CHECKING…' : 'RESUME REVEAL')),
      ]));
}

class _AssetReceipt extends StatelessWidget {
  const _AssetReceipt({
    required this.data,
    required this.onSendAnother,
    required this.onDone,
  });
  final Map<String, Object?> data;
  final VoidCallback onSendAnother;
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    final operation = (data['operation'] as Map);
    return SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.check_circle_rounded,
          size: 70, color: KasVaultTheme.mint),
      const Text('ASSET SENT',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
      const SizedBox(height: 18),
      _Card(children: [
        _Row('Asset', operation['kind'].toString().toUpperCase()),
        _Row('Recipient', data['recipient'].toString()),
        if (data['kcc20'] != true) ...[
          _Row('Commit TX', data['commitTransactionId'].toString()),
          _Row('Reveal TX', data['revealTransactionId'].toString()),
          _Row('Commit fee',
              '${formatSompi((data['commitFeeSompi'] as num).toInt())} KAS'),
        ] else ...[
          _Row('Transaction ID', data['revealTransactionId'].toString()),
          _Row('Template hash', data['templateHash'].toString()),
          _Row('Mass', formatEnglishDecimal(data['mass'].toString())),
        ],
        _Row(data['kcc20'] == true ? 'Network fee' : 'Reveal fee',
            '${formatSompi((data['revealFeeSompi'] as num).toInt())} KAS'),
      ]),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: onSendAnother,
        icon: const Icon(Icons.add_rounded),
        label: const Text('SEND ANOTHER ASSET'),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: onDone,
        child: const Text('BACK TO WALLET'),
      ),
    ]));
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line)),
      child: Column(children: children));
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: KasVaultTheme.muted)),
        const SizedBox(width: 12),
        Expanded(
            child: SelectableText(value,
                textAlign: TextAlign.right,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))
      ]));
}
