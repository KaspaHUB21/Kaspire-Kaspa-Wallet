import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../services/kcc20_payment_plan.dart';
import '../widgets/hub21_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/asset_send_intent.dart';
import '../decimal_input_formatter.dart';
import '../models/kaspa_payment_request.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../platform.dart';
import '../services/kaspa_api.dart';
import '../services/kcc20_standard_service.dart';
import '../services/kcc20_compound.dart';
import '../services/activity_store.dart';
import '../services/app_settings.dart';
import '../services/native_security.dart';
import '../widgets/krc721_image.dart';
import '../services/signer_service.dart';
import '../services/preferences_service.dart';
import '../theme.dart';
import 'address_book_screen.dart';
import 'qr_scanner_screen.dart';

enum _AssetKind { krc20, kcc20, krc721, kns }

class AssetSendScreen extends StatefulWidget {
  const AssetSendScreen({
    super.key,
    required this.address,
    required this.onDone,
    this.initialAsset,
    this.api,
  });
  final String address;
  final VoidCallback onDone;
  final AssetSendIntent? initialAsset;
  final KaspaApi? api;
  @override
  State<AssetSendScreen> createState() => _AssetSendScreenState();
}

class _AssetSendScreenState extends State<AssetSendScreen> {
  String get _pendingKey =>
      'kaspire_pending_inscription_v2_${widget.address.toLowerCase()}';
  String get _compoundKey =>
      'kaspire_pending_kcc20_compound_${widget.address.toLowerCase()}';
  Map<String, Object?>? _pendingCompound;
  late final KaspaApi _api;
  final _security = NativeSecurity();
  final _signer = SignerService();
  final _preferences = PreferencesService();
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
  bool _kronTransfer = false;
  Map<String, Object?>? _pending;
  String? _error;
  String? _status;
  bool _working = true;
  bool _refreshing = false;
  int _nftLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? KaspaApi();
    final intent = widget.initialAsset;
    _kind = intent?.kind == 'krc721'
        ? _AssetKind.krc721
        : intent?.kind == 'kcc20'
            ? _AssetKind.kcc20
            : intent?.kind == 'kns'
                ? _AssetKind.kns
                : _AssetKind.krc20;
    if (intent?.wallet != null) _applyWallet(intent!.wallet!);
    if (intent?.nft != null) {
      _nft = intent!.nft;
      _nfts = [_nft!];
    }
    _load();
  }

  void _applyWallet(WalletSnapshot wallet) {
    final intent = widget.initialAsset;
    final token = _token?.symbol ?? intent?.symbol;
    final cid = _covenantToken?.covenantId ??
        (_kind == _AssetKind.kcc20 ? intent?.assetId : null);
    final collection = _collection?.symbol ?? intent?.symbol;
    final domainId = _domain?.assetId ?? intent?.assetId;
    _wallet = wallet;
    _token = wallet.krc20Tokens
            .where((a) => a.symbol.toLowerCase() == token?.toLowerCase())
            .firstOrNull ??
        wallet.krc20Tokens.firstOrNull;
    // A ticker is not unique for covenant tokens. Never choose a different
    // covenant just because its ticker matches the selected token.
    _covenantToken = cid != null
        ? wallet.kcc20Tokens
            .where((a) => (a.covenantId ?? a.id) == cid)
            .firstOrNull
        : wallet.kcc20Tokens.firstOrNull;
    _collection = wallet.krc721Collections
            .where((a) => a.symbol.toLowerCase() == collection?.toLowerCase())
            .firstOrNull ??
        wallet.krc721Collections.firstOrNull;
    _domain = wallet.knsDomains
            .where((d) =>
                d.assetId == domainId && domainId != null ||
                d.name.toLowerCase() ==
                    (_domain?.name ?? intent?.domainName)?.toLowerCase())
            .firstOrNull ??
        wallet.knsDomains.firstOrNull;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var pendingRaw = prefs.getString(_pendingKey);
      final compoundRaw = prefs.getString(_compoundKey);
      _pendingCompound = compoundRaw == null
          ? null
          : (jsonDecode(compoundRaw) as Map).cast<String, Object?>();
      const legacyPendingKey = 'kaspire_pending_inscription_v1';
      final legacyPendingRaw = prefs.getString(legacyPendingKey);
      if (pendingRaw == null && legacyPendingRaw != null) {
        final legacy =
            (jsonDecode(legacyPendingRaw) as Map).cast<String, Object?>();
        final operation =
            (legacy['operation'] as Map?)?.cast<String, Object?>();
        if (operation?['sender']?.toString().toLowerCase() ==
            widget.address.toLowerCase()) {
          pendingRaw = legacyPendingRaw;
          await prefs.setString(_pendingKey, legacyPendingRaw);
          await prefs.remove(legacyPendingKey);
        }
      }
      if (!mounted) return;
      final hasDisplaySnapshot = _wallet != null;
      setState(() {
        _pending = pendingRaw == null
            ? null
            : (jsonDecode(pendingRaw) as Map).cast<String, Object?>();
        _working = false;
        _refreshing = true;
      });
      // Load NFT pages only for the NFT tab, not for every asset transfer.
      if (_kind == _AssetKind.krc721 && _collection != null) {
        unawaited(_loadNfts(_collection!));
      }
      void update(WalletSnapshot wallet) {
        if (!mounted ||
            _working ||
            _operation != null ||
            _kcc20Review != null) {
          return;
        }
        final previous = _collection?.symbol;
        setState(() => _applyWallet(wallet));
        if (_kind == _AssetKind.krc721 &&
            _collection != null &&
            previous != _collection?.symbol) {
          unawaited(_loadNfts(_collection!));
        }
      }

      final wallet = await _api.loadWallet(widget.address,
          includeNativeTransactions: false,
          includeAssetHistory: false,
          includeMarketData: false,
          onProgress: hasDisplaySnapshot ? null : update);
      update(wallet);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
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
    final generation = ++_nftLoadGeneration;
    final selected =
        _nft?.ticker.toLowerCase() == collection.symbol.toLowerCase()
            ? _nft
            : null;
    setState(() {
      _collection = collection;
      _nfts = selected == null ? const [] : [selected];
      _nft = selected;
    });
    try {
      final all = <WalletNft>[];
      int? offset = 0;
      while (offset != null && all.length < 1000) {
        final page = await _api.loadNftCollection(
            widget.address, collection.symbol,
            offset: offset);
        if (!mounted || generation != _nftLoadGeneration) return;
        all.addAll(page.nfts);
        offset = page.nextOffset;
        setState(() {
          _nfts = [
            ...all,
            if (selected != null &&
                !all.any((n) => n.tokenId == selected.tokenId) &&
                offset != null)
              selected
          ];
          _nft = _nfts
                  .where((nft) =>
                      nft.tokenId ==
                      (_nft?.tokenId ?? widget.initialAsset?.tokenId))
                  .firstOrNull ??
              _nfts.firstOrNull;
        });
      }
    } catch (e) {
      if (mounted && generation == _nftLoadGeneration) {
        setState(() => _error = '$e');
      }
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
      _status = 'Preparing asset transfer…';
    });
    try {
      if (_kind == _AssetKind.kcc20 &&
          (_pendingCompound?['finalPayment'] != null ||
              _pendingCompound?['signedPlan'] != null)) {
        throw StateError(
            'A previously signed KCC20 payment is awaiting confirmation. Use Continue KCC20 transfer to check it before preparing another payment.');
      }
      if (!await _security.hasNativeWalletFor(widget.address)) {
        throw StateError('This is a watch-only wallet.');
      }
      final recipient = await _api.resolveWalletInput(_recipient.text);
      if (AppSettings.recipientAllowlist.value &&
          !await _preferences.isAddressBookRecipient(recipient)) {
        throw StateError(
          'This recipient is not in your address book. Add it first or '
          'disable the recipient allowlist.',
        );
      }
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
          final isStandard = Kcc20StandardService.isStandard(token.standard);
          final dynamicCells = isStandard || token.standard == 'kron-native';
          if (!dynamicCells && token.validationStatus != 'verified') {
            throw StateError('Only indexer-verified KCC20 tokens can be sent.');
          }
          if (!dynamicCells &&
              (!token.discoveryComplete || token.kcc20Cells.isEmpty)) {
            throw StateError(
                'KCC20 cell discovery is incomplete. Refresh and verify the token before sending.');
          }
          final raw = _rawTokenAmount(token, _amount.text);
          if (raw == null) {
            throw StateError(
                'Invalid amount, too many decimals, or insufficient token balance.');
          }
          final standardStep = isStandard
              ? await _api.loadStandardKcc20SigningBatch(
                  widget.address, token.covenantId!, int.parse(raw),
                  sourceStandard: token.standard,
                  fullPlan: !isWindowsDesktop,
                  isCancelled: () => !mounted,
                  onProgress: (stage) {
                    if (mounted) setState(() => _status = stage);
                  })
              : null;
          if (!mounted) return;
          final availableCells = standardStep?.cells ??
              (token.standard == 'kron-native'
                  ? await _api.loadKronSigningCells(
                      widget.address, token.covenantId!, int.parse(raw))
                  : token.kcc20Cells);
          // Keep optional verified dust inputs. Reapplying the legacy minimal
          // planner here would discard them and undo in-payment consolidation.
          final step = standardStep ??
              (token.standard == 'kron-native'
                  ? null
                  : planKcc20Step(availableCells, int.parse(raw), 2));
          final compound = step?.compound == true;
          final cells = step?.cells ?? availableCells;
          final stepAmount = step?.amount ?? int.parse(raw);
          final stepRecipient = compound ? widget.address : recipient;
          if (!isStandard && token.standard != 'kron-native') {
            await _api.verifyKcc20CellsOnOwnNode(cells, token.covenantId!);
          }
          final fundingUtxos = await _api.loadUtxos(widget.address);
          if (!mounted) return;
          setState(() => _status =
              'Verifying the covenant transaction in the native core…');
          final request = <String, Object?>{
            'sender': widget.address,
            'recipient': stepRecipient,
            'covenantId': token.covenantId,
            'ticker': token.symbol,
            'amount': stepAmount,
            'decimals': token.decimals,
            'feeRate': 100.0,
            'templateHash':
                standardStep?.templateId ?? token.templateHash ?? '',
            'cells': cells.map((cell) => cell.toJson()).toList(),
            'fundingUtxosJson': fundingUtxos,
          };
          Map<String, Object?> review;
          Map<String, Object?> signingRequest = request;
          if (dynamicCells) {
            if (cells.any((cell) =>
                cell.redeemScript == null || cell.redeemScript!.isEmpty)) {
              throw StateError(
                  'KRON signing data is incomplete. Refresh the wallet.');
            }
            final kronRequest = <String, Object?>{
              'sender': widget.address,
              'recipient': stepRecipient,
              'covenantId': token.covenantId,
              'ticker': token.symbol,
              'amount': stepAmount,
              'decimals': token.decimals,
              'feeRate': 100.0,
              'templateHash':
                  standardStep?.templateId ?? token.templateHash ?? '',
              'cells': cells
                  .map((cell) => <String, Object?>{
                        'transactionId': cell.transactionId,
                        'index': cell.index,
                        'valueSompi': cell.valueSompi,
                        'blockDaaScore': cell.blockDaaScore,
                        'scriptPublicKey': cell.scriptPublicKey,
                        'tokenAmount': cell.tokenAmount,
                        'redeemScript': cell.redeemScript,
                      })
                  .toList(),
              'fundingUtxosJson': fundingUtxos,
            };
            if (isStandard && cells.length > (standardStep?.inputLimit ?? 3)) {
              kronRequest['recipient'] = recipient;
              kronRequest['amount'] = int.parse(raw);
              final plan = await _security.prepareKcc20Plan(kronRequest);
              final steps = (plan['steps'] as List).cast<Map>();
              final last = steps.last.cast<String, Object?>();
              final locked =
                  cells.fold<int>(0, (sum, cell) => sum + cell.valueSompi);
              final lockedOut = (last['lockedKasOutputSompi'] as num).toInt();
              review = {
                ...last,
                ...plan,
                'paymentPlan': true,
                'feeSompi': plan['totalFeeSompi'],
                'networkFeeSompi': plan['totalFeeSompi'],
                'mass': last['feeMass'],
                'lockedKasSompi': locked,
                'lockedKasOutputSompi': lockedOut,
                'lockedKasTopUpSompi':
                    lockedOut > locked ? lockedOut - locked : 0,
                'lockedKasReleasedSompi':
                    locked > lockedOut ? locked - lockedOut : 0,
                'validation': 'Complete native plan + local node',
                'covenantId': token.covenantId,
              };
              signingRequest = kronRequest;
              operation.addAll({
                'ticker': token.symbol,
                'amount': raw,
                'displayAmount':
                    formatRawTokenAmount(BigInt.parse(raw), token.decimals),
                'recipient': recipient,
                'covenantId': token.covenantId,
                'standard': token.standard,
                'paymentPlan': true,
                'requiredCells': cells.length,
                'transactionCount': plan['transactionCount'],
              });
              if (mounted) {
                setState(() {
                  _operation = operation;
                  _kcc20Request = signingRequest;
                  _kcc20Review = review;
                  _kronTransfer = true;
                  _working = false;
                });
              }
              return;
            }
            final prepared = await _security.prepareKronTransfer(kronRequest);
            if (!mounted) return;
            signingRequest =
                (prepared['psktRequest'] as Map).cast<String, Object?>();
            final psktReview = await _security.preparePskt(signingRequest);
            review = <String, Object?>{
              ...prepared,
              ...psktReview,
              'reviewHash': psktReview['reviewHash'],
              'networkFeeSompi': prepared['feeSompi'],
              'mass': prepared['feeMass'],
              'covenantId': token.covenantId,
              'validation': dynamicCells
                  ? 'Local node and native core'
                  : 'Indexer verified',
              'kron': token.standard == 'kron-native',
            };
          } else {
            review = await _security.prepareKcc20Transfer(request);
          }
          operation['ticker'] = token.symbol;
          operation['amount'] = stepAmount.toString();
          operation['displayAmount'] =
              formatRawTokenAmount(BigInt.from(stepAmount), token.decimals);
          operation['recipient'] = stepRecipient;
          operation['compound'] = compound;
          if (compound) operation['operationLabel'] = 'KCC20 auto-compound';
          operation['intendedRecipient'] = recipient;
          operation['intendedAmount'] = raw;
          operation['intendedDisplayAmount'] = _amount.text.trim();
          operation['covenantId'] = token.covenantId;
          operation['standard'] = token.standard;
          operation['requiredCells'] = step?.requiredCells ?? cells.length;
          operation['transactionCount'] = step?.transactionCount ?? 1;
          final previous = _pendingCompound?['operation'] as Map?;
          operation['completedSteps'] = previous != null &&
                  previous['covenantId'] == token.covenantId &&
                  previous['intendedRecipient'] == recipient &&
                  previous['intendedAmount'] == raw
              ? ((previous['completedSteps'] as num?)?.toInt() ?? 0) + 1
              : 0;
          if (mounted) {
            setState(() {
              _operation = operation;
              _kcc20Request = signingRequest;
              _kcc20Review = review;
              _kronTransfer = dynamicCells;
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
          _status = null;
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
      if (operation['paymentPlan'] == true) {
        if (_pendingCompound?['signedPlan'] != null) {
          throw StateError(
              'An approved plan is saved. Use Continue KCC20 transfer; do not sign again.');
        }
        final signed = await _security.signKcc20Plan(
            request, review['reviewHash']! as String);
        final steps = review['steps'] as List;
        final transactions =
            (signed['transactions'] as List).asMap().entries.map((entry) {
          final step = steps[entry.key] as Map;
          final terms = ((step['psktRequest'] as Map)['tradeSummary'] as Map);
          final compound = entry.key + 1 < steps.length;
          return {
            ...(entry.value as Map),
            'feeSompi': step['feeSompi'],
            'operation': {
              ...operation,
              'recipient': compound ? widget.address : operation['recipient'],
              'amount': terms['amount'].toString(),
              'displayAmount': formatRawTokenAmount(
                  BigInt.parse(terms['amount'].toString()),
                  (request['decimals'] as num).toInt()),
              'compound': compound,
              if (compound) 'operationLabel': 'KCC20 auto-compound',
            }
          };
        }).toList();
        final continuation = <String, Object?>{
          'operation': operation,
          'signedPlan': {
            'sender': widget.address,
            'operation': operation,
            'reviewHash': signed['reviewHash'],
            'totalFeeSompi': signed['totalFeeSompi'],
            'transactions': transactions,
            'nextStep': 0,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          }
        };
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(_compoundKey, jsonEncode(continuation))) {
          throw StateError(
              'Could not save KCC20 plan. No transaction was sent.');
        }
        _pendingCompound = continuation;
        await _resumeKcc20PaymentPlan();
        return;
      }
      final signed = _kronTransfer
          ? await _security.signPskt(request, review['reviewHash']! as String)
          : await _security.signKcc20Transfer(
              request,
              review['reviewHash']! as String,
            );
      if (mounted) {
        setState(
            () => _status = 'Transaction signed. Sending to Kaspa mainnet…');
      }
      final expectedTransactionId = signed['transactionId']! as String;
      if (operation['compound'] == true) {
        final continuation = <String, Object?>{
          'operation': operation,
          'transactionId': expectedTransactionId
        };
        await (await SharedPreferences.getInstance())
            .setString(_compoundKey, jsonEncode(continuation));
        if (mounted) setState(() => _pendingCompound = continuation);
      }
      if (operation['compound'] != true && _pendingCompound != null) {
        final pendingOperation = _pendingCompound!['operation'] as Map;
        if (pendingOperation['covenantId'] == operation['covenantId'] &&
            pendingOperation['intendedRecipient'] == operation['recipient'] &&
            pendingOperation['intendedAmount'] == operation['amount']) {
          final continuation = <String, Object?>{
            ..._pendingCompound!,
            'finalPayment': {
              'transactionId': expectedTransactionId,
              'signedTxJson': signed['wrpcJson'],
              'operation': operation,
              'feeSompi': review['feeSompi']
            }
          };
          await (await SharedPreferences.getInstance())
              .setString(_compoundKey, jsonEncode(continuation));
          _pendingCompound = continuation;
        }
      }
      final transactionId = await _api.broadcastKcc20(
        signed['wrpcJson']! as String,
        expectedTransactionId: expectedTransactionId,
      );
      if (transactionId.isEmpty) {
        throw StateError('Broadcast was accepted without a transaction ID.');
      }
      if (operation['compound'] != true && _pendingCompound != null) {
        final pendingOperation = (_pendingCompound!['operation'] as Map);
        if (pendingOperation['covenantId'] == operation['covenantId'] &&
            pendingOperation['intendedRecipient'] == operation['recipient'] &&
            pendingOperation['intendedAmount'] == operation['amount']) {
          await (await SharedPreferences.getInstance()).remove(_compoundKey);
          _pendingCompound = null;
        }
      }
      await ActivityStore().recordAssetTransfer(
        wallet: widget.address,
        operation: operation,
        transactionId: transactionId,
        timestamp: DateTime.now(),
      );
      if (!mounted) return;
      if (operation['compound'] == true) {
        await _continueKcc20Compound(operation, transactionId);
        return;
      }
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
          'kron': operation['standard'] == 'kron-native',
          'mass': review['mass'],
          'templateHash': review['templateHash'],
        };
        _kronTransfer = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _status = null;
          if (_pendingCompound?['signedPlan'] != null) {
            _kcc20Request = null;
            _kcc20Review = null;
            _kronTransfer = false;
          }
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _continueKcc20Compound(
      Map operation, String transactionId) async {
    if (!mounted) return;
    if (_pendingCompound?['signedPlan'] != null) {
      setState(() {
        _working = true;
        _error = null;
      });
      try {
        await _resumeKcc20PaymentPlan();
      } catch (e) {
        if (mounted) {
          setState(() {
            _working = false;
            _status = null;
            _error = e.toString();
          });
        }
      }
      return;
    }
    final payment = _pendingCompound?['finalPayment'] as Map?;
    if (payment != null) {
      setState(() {
        _working = true;
        _error = null;
        _status =
            'Checking the already signed final payment. No duplicate will be sent…';
      });
      try {
        final id = payment['transactionId'].toString();
        if (!await _api.isKcc20TransactionAccepted(id)) {
          final bytes = payment['signedTxJson'];
          if (bytes is! String) {
            throw StateError(
                'Final payment $id is not confirmed. No duplicate will be created.');
          }
          // Retry only the identical, already-approved transaction/outpoints.
          await _api.broadcastKcc20(bytes, expectedTransactionId: id);
        }
        await ActivityStore().recordAssetTransfer(
            wallet: widget.address,
            operation: payment['operation'] as Map,
            transactionId: id,
            timestamp: DateTime.now());
        await (await SharedPreferences.getInstance()).remove(_compoundKey);
        if (!mounted) return;
        setState(() {
          _pendingCompound = null;
          _working = false;
          _status = null;
          _receipt = {
            'operation': payment['operation'],
            'recipient': (payment['operation'] as Map)['recipient'],
            'revealTransactionId': id,
            'revealFeeSompi': payment['feeSompi'],
            'kcc20': true
          };
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _working = false;
            _status = null;
            _error = e.toString();
          });
        }
      }
      return;
    }
    setState(() {
      _working = true;
      _error = null;
      _status = 'Waiting for the compounded cell. Recipient NOT paid…';
    });
    var indexed = false;
    final standard =
        Kcc20StandardService.isStandard(operation['standard']?.toString());
    if (standard) {
      try {
        await _api.waitForStandardKcc20Cell(
            widget.address, operation['covenantId'].toString(), transactionId,
            sourceStandard: operation['standard']?.toString(),
            isCancelled: () => !mounted,
            onProgress: (stage) {
              if (mounted) setState(() => _status = stage);
            });
        if (!mounted) return;
        final token = _wallet?.kcc20Tokens
            .where((t) => t.covenantId == operation['covenantId'])
            .firstOrNull;
        if (token != null) {
          _covenantToken = token;
          indexed = true;
        }
      } catch (_) {/* Saved continuation remains available on timeout. */}
    }
    for (var attempt = 0; !standard && attempt < 20 && mounted; attempt++) {
      try {
        final wallet = await _api.loadWallet(widget.address,
            includeNativeTransactions: false,
            includeAssetHistory: false,
            includeMarketData: false);
        if (!mounted) return;
        final token = wallet.kcc20Tokens
            .where((t) => t.covenantId == operation['covenantId'])
            .firstOrNull;
        if (token == null ||
            (!Kcc20StandardService.isStandard(token.standard) &&
                !token.kcc20Cells
                    .any((c) => c.transactionId == transactionId))) {
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        _applyWallet(wallet);
        _covenantToken = token;
        indexed = true;
        break;
      } catch (_) {/* Indexer lag never authorizes a new payment. */}
      await Future<void>.delayed(Duration(seconds: attempt < 5 ? 3 : 6));
    }
    if (!mounted) return;
    setState(() {
      _kind = _AssetKind.kcc20;
      _operation = null;
      _kcc20Request = null;
      _kcc20Review = null;
      _kronTransfer = false;
      _working = false;
      _status = null;
      _recipient.text = operation['intendedRecipient'].toString();
      _amount.text = operation['intendedDisplayAmount'].toString();
      if (!indexed) {
        _error =
            'Compound transaction: $transactionId. Recipient NOT paid. The indexer has not confirmed the new cell yet. Use Continue KCC20 transfer later.';
      }
    });
    if (indexed) await _prepare();
  }

  Future<void> _resumeKcc20PaymentPlan() async {
    final saved = _pendingCompound!;
    final plan = (saved['signedPlan'] as Map).cast<String, Object?>();
    final prefs = await SharedPreferences.getInstance();
    final finalTx = await runKcc20PaymentPlan(
      plan,
      widget.address,
      save: (checkpoint) async {
        final value = {...saved, 'signedPlan': checkpoint};
        if (!await prefs.setString(_compoundKey, jsonEncode(value))) {
          throw StateError(
              'Could not save KCC20 plan checkpoint. Processing stopped safely.');
        }
        _pendingCompound = value;
      },
      accepted: _api.kcc20PlanTransactionAccepted,
      broadcast: (bytes, id) async {
        await _api.broadcastKcc20(bytes, expectedTransactionId: id);
      },
      record: (tx) => ActivityStore().recordAssetTransfer(
          wallet: widget.address,
          operation: tx['operation'] as Map,
          transactionId: tx['transactionId'] as String,
          timestamp: DateTime.now()),
      check: () {
        if (!mounted) {
          throw StateError('KCC20 plan saved. Reopen this wallet to continue.');
        }
      },
      progress: (message) {
        if (mounted) setState(() => _status = message);
      },
    );
    if (!await prefs.remove(_compoundKey)) {
      throw StateError(
          'Payment confirmed, but the recovery journal could not be cleared. Continue will only check the same transaction.');
    }
    if (!mounted) return;
    setState(() {
      _pendingCompound = null;
      _working = false;
      _status = null;
      _error = null;
      _kcc20Request = null;
      _kcc20Review = null;
      _kronTransfer = false;
      _receipt = {
        'operation': saved['operation'],
        'recipient': (saved['operation'] as Map)['recipient'],
        'revealTransactionId': finalTx['transactionId'],
        'revealFeeSompi': plan['totalFeeSompi'],
        'kcc20': true
      };
    });
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

  WalletAsset? get _selectedFungible => switch (_kind) {
        _AssetKind.krc20 => _token,
        _AssetKind.kcc20 => _covenantToken,
        _ => null,
      };

  void _useMaximum() {
    final asset = _selectedFungible;
    if (asset != null) _amount.text = _assetInputBalance(asset);
  }

  String _assetInputBalance(WalletAsset asset) {
    final raw = BigInt.tryParse(asset.rawBalance ?? '');
    if (raw == null) {
      return asset.balance
          .toStringAsFixed(asset.decimals.clamp(0, 18))
          .replaceFirst(RegExp(r'\.?0+$'), '');
    }
    if (asset.decimals <= 0) return raw.toString();
    final digits = raw.toString().padLeft(asset.decimals + 1, '0');
    final split = digits.length - asset.decimals;
    final fraction = digits.substring(split).replaceFirst(RegExp(r'0+$'), '');
    return fraction.isEmpty
        ? digits.substring(0, split)
        : '${digits.substring(0, split)}.$fraction';
  }

  Future<void> _scanRecipient() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScannerScreen()),
    );
    if (value == null) return;
    final request = KaspaPaymentRequest.tryParse(value);
    if (request != null) _recipient.text = request.address;
  }

  Future<void> _chooseContact() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const AddressBookScreen(selectAddress: true),
      ),
    );
    if (address != null) _recipient.text = address;
  }

  Widget _recipientInput() => TextField(
        controller: _recipient,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Address / KNS / .k name',
          hintText: 'Long press to paste',
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Address book',
                onPressed: _chooseContact,
                icon: const Icon(Icons.contacts_outlined),
              ),
              IconButton(
                tooltip: 'Scan recipient QR code',
                onPressed: _scanRecipient,
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ],
          ),
        ),
      );

  Widget _amountInput(WalletAsset asset) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    DecimalInputFormatter(
                      decimalPlaces: asset.decimals.clamp(0, 8),
                    ),
                  ],
                  decoration: const InputDecoration(labelText: 'Amount'),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _useMaximum,
                  child: Text(buttonLabel('MAX')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Hub21Readable(
              child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Available',
                style: TextStyle(color: KasVaultTheme.muted, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                '${_assetBalance(asset)} ${asset.symbol}',
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.right,
              )),
            ],
          )),
        ],
      );

  Widget _networkSummary() => Container(
        padding: const EdgeInsets.all(18),
        decoration: KasVaultTheme.isDecorative
            ? kaspireDecorativeDecoration(radius: 18, rim: 2.5)
            : BoxDecoration(
                color: KasVaultTheme.panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KasVaultTheme.line),
              ),
        child: const Column(
          children: [
            _TransferFact(label: 'Network', value: 'Kaspa Mainnet'),
            SizedBox(height: 12),
            _TransferFact(label: 'Fee', value: 'Live node estimate'),
            SizedBox(height: 12),
            _TransferFact(label: 'Signer', value: 'Rusty Kaspa v2.1.0'),
          ],
        ),
      );

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
        key: ValueKey(covenantReview['reviewHash']),
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
        if (_pendingCompound != null) ...[
          const Text('KCC20 TRANSFER NOT COMPLETED',
              style: TextStyle(
                  color: Color(0xFFFFC857), fontWeight: FontWeight.w900)),
          Text(_pendingCompound!['signedPlan'] != null
              ? 'An approved payment plan is saved. Continue sends only the exact already-approved transactions. No new signature or duplicate payment is created. The recipient is paid by the final transaction.'
              : _pendingCompound!['finalPayment'] != null
                  ? 'Final payment confirmation is pending. Continue to check the existing transaction; no duplicate payment will be created.'
                  : 'Self-compound confirmation is pending. The recipient has NOT been paid. Continue with a new review; every transaction still requires approval.'),
          OutlinedButton(
              onPressed: _working
                  ? null
                  : () => _continueKcc20Compound(
                      _pendingCompound!['operation'] as Map,
                      _pendingCompound!['transactionId'].toString()),
              child: const Text('Continue KCC20 transfer')),
          const SizedBox(height: 16),
        ],
        if (_refreshing) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('Refreshing asset balances…'),
          const SizedBox(height: 12),
        ],
        Hub21Readable(
            child: Text(displayLabel('SEND ASSET'),
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900))),
        const SizedBox(height: 8),
        const Hub21Readable(
            child: Text(
                'KRC-20, KRC-721 and KNS use commit/reveal. KCC20 is signed locally and submitted directly to Kaspa mainnet.',
                style: TextStyle(color: KasVaultTheme.muted))),
        const SizedBox(height: 20),
        SegmentedButton<_AssetKind>(
            segments: const [
              ButtonSegment(value: _AssetKind.krc20, label: Text('KRC-20')),
              ButtonSegment(value: _AssetKind.kcc20, label: Text('KCC20')),
              ButtonSegment(value: _AssetKind.krc721, label: Text('KRC-721')),
              ButtonSegment(value: _AssetKind.kns, label: Text('KNS')),
            ],
            selected: {
              _kind
            },
            onSelectionChanged: (v) {
              setState(() => _kind = v.first);
              if (_kind == _AssetKind.krc721 &&
                  _collection != null &&
                  _nfts.isEmpty) {
                unawaited(_loadNfts(_collection!));
              }
            }),
        const SizedBox(height: 18),
        if (_working && _wallet == null)
          const Center(child: CircularProgressIndicator()),
        if (_kind == _AssetKind.krc20) ...[
          DropdownButtonFormField<WalletAsset>(
              key: ObjectKey(_wallet),
              initialValue: _token,
              isExpanded: true,
              isDense: false,
              itemHeight: 86,
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
                        height: 70,
                        width: double.infinity,
                        child: _Krc20TokenOption(
                          asset: a,
                          balance: _assetBalance(a),
                        ),
                      )))
                  .toList(),
              onChanged: (v) => setState(() => _token = v)),
        ],
        if (_kind == _AssetKind.kcc20) ...[
          DropdownButtonFormField<WalletAsset>(
              key: ObjectKey(_wallet),
              initialValue: _covenantToken,
              isExpanded: true,
              isDense: false,
              itemHeight: 86,
              decoration: const InputDecoration(
                labelText: 'Token / covenant',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: EdgeInsets.fromLTRB(14, 18, 10, 10),
                constraints: BoxConstraints(minHeight: 86),
              ),
              items: (_wallet?.kcc20Tokens ?? const [])
                  .map((asset) => DropdownMenuItem(
                      value: asset,
                      child: SizedBox(
                        height: 70,
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
              Kcc20StandardService.isStandard(_covenantToken!.standard)
                  ? 'KCC20 · Signing cells are verified on the local node before review.'
                  : _covenantToken!.standard == 'kron-native'
                      ? 'KRON balance · Signing cells are verified on the local node before review.'
                      : _covenantToken!.discoveryComplete
                          ? 'Indexer verified · ${_covenantToken!.kcc20Cells.length} spendable cell(s)'
                          : 'Sending disabled: cell discovery is incomplete.',
              style: TextStyle(
                color:
                    Kcc20StandardService.isStandard(_covenantToken!.standard) ||
                            _covenantToken!.standard == 'kron-native' ||
                            _covenantToken!.discoveryComplete
                        ? KasVaultTheme.mint
                        : const Color(0xFFFFB65C),
                fontSize: 12,
              ),
            ),
        ],
        if (_kind == _AssetKind.krc721) ...[
          DropdownButtonFormField<WalletAsset>(
              key: ObjectKey(_wallet),
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
              key: ObjectKey(_wallet),
              initialValue: _domain,
              decoration: const InputDecoration(labelText: 'Domain'),
              items: (_wallet?.knsDomains ?? const [])
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
                  .toList(),
              onChanged: (v) => setState(() => _domain = v)),
        const SizedBox(height: 18),
        _recipientInput(),
        if (_selectedFungible != null) ...[
          const SizedBox(height: 14),
          _amountInput(_selectedFungible!),
        ],
        const SizedBox(height: 22),
        _networkSummary(),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!,
                  style: const TextStyle(color: Color(0xFFFF8A65)))),
        if (_working && _status != null) ...[
          const SizedBox(height: 14),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Hub21Readable(child: Text(_status!)),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
            onPressed: _working ? null : _prepare,
            icon: const Icon(Icons.shield_outlined),
            label: Text(buttonLabel(
              _working ? 'PREPARING…' : 'REVIEW ASSET TRANSFER',
            ))),
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
      color: KasVaultTheme.mint.withValues(alpha: .12),
      child: Center(
        child: Text(
          asset.symbol.isEmpty ? '?' : asset.symbol.substring(0, 1),
          style: TextStyle(
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
              color: KasVaultTheme.mint.withValues(alpha: .12),
              child: asset.imageUrl == null
                  ? fallback
                  : Padding(
                      padding: const EdgeInsets.all(3),
                      child: Krc721Image(
                        asset.imageUrl!,
                        fit: BoxFit.contain,
                        placeholder: fallback,
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

class _Kcc20Review extends StatefulWidget {
  const _Kcc20Review({
    super.key,
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
  State<_Kcc20Review> createState() => _Kcc20ReviewState();
}

class _Kcc20ReviewState extends State<_Kcc20Review> {
  bool _acknowledged = false;
  Map<String, Object?> get operation => widget.operation;
  Map<String, Object?> get review => widget.review;
  bool get working => widget.working;
  String? get status => widget.status;
  String? get error => widget.error;
  VoidCallback get onCancel => widget.onCancel;
  VoidCallback get onConfirm => widget.onConfirm;
  int get _remaining => (operation['transactionCount'] as num?)?.toInt() ?? 1;
  int get _completed => (operation['completedSteps'] as num?)?.toInt() ?? 0;
  bool get _isPlan => operation['paymentPlan'] == true;
  bool get _needsAcknowledgement => _remaining > 3 && _completed == 0;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Review KCC20 Covenant Transfer',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Hub21Readable(
                child: const Text(
              'The native core reconstructed every state script and will execute every input locally before sending the transaction to Kaspa mainnet.',
              style: TextStyle(color: KasVaultTheme.muted),
            )),
            const SizedBox(height: 8),
            Hub21Readable(
                child: const Text(
              'Toccata fees use fee mass (compute or normalized transient). Storage mass is shown separately as a hard capacity limit.',
              style: TextStyle(color: KasVaultTheme.muted),
            )),
            const SizedBox(height: 18),
            if (_remaining > 1 || _completed > 0) ...[
              Hub21Readable(
                  child: Text(
                      'MULTI-TRANSACTION PAYMENT · $_remaining transaction(s) remaining, including the recipient payment. $_completed self-consolidation(s) completed.\n${_isPlan ? 'ONE approval covers this complete fixed plan, including the final recipient payment. The TOTAL network fees are shown below. Interrupted plans resume only the exact already-approved transactions; no fees, amounts or recipient can be changed.' : 'The current balance needs ${operation['requiredCells']} token cells to cover this payment. Each transaction requires separate approval and a network fee. You can stop and resume the saved transfer later.'}',
                      style: const TextStyle(fontWeight: FontWeight.w700))),
              const SizedBox(height: 12),
            ],
            if (_needsAcknowledgement)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    'I understand that this payment needs approximately $_remaining separate on-chain transactions, each with its own fee.'),
                value: _acknowledged,
                onChanged: working
                    ? null
                    : (value) => setState(() => _acknowledged = value == true),
              ),
            if (operation['compound'] == true) ...[
              const Text('AUTO-COMPOUND · SELF-TRANSFER',
                  style: TextStyle(
                      color: Color(0xFFFFC857), fontWeight: FontWeight.w900)),
              Text(
                  'Combines your own token cells first. The recipient has NOT been paid. After confirmation, Kaspire prepares the next step for review. Each step has a separate network fee.\nIntended payment: ${operation['intendedDisplayAmount']} ${operation['ticker']} to ${operation['intendedRecipient']}'),
              const SizedBox(height: 18),
            ],
            _Card(children: [
              _Row('Validation',
                  review['validation']?.toString() ?? 'Indexer verified'),
              _Row('Token', operation['ticker'].toString()),
              _Row(
                'Amount',
                '${formatEnglishDecimal(operation['displayAmount'].toString())} ${operation['ticker']}',
              ),
              _Row('Recipient', operation['recipient'].toString()),
              _Row('Covenant ID', review['covenantId'].toString()),
              _Row('Template hash', review['templateHash'].toString()),
              if (_isPlan)
                _Row('Original token cells',
                    operation['requiredCells'].toString()),
              _Row(
                  _isPlan
                      ? 'Final transaction token inputs'
                      : 'Covenant inputs',
                  review['covenantInputCount'].toString()),
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
              _Row(_isPlan ? 'TOTAL network fees' : 'Network fee',
                  '${formatSompi((review['feeSompi'] as num).toInt())} KAS'),
              _Row(_isPlan ? 'Final transaction fee mass' : 'Effective mass',
                  formatEnglishDecimal(review['mass'].toString())),
              _Row('Compute mass',
                  formatEnglishDecimal(review['computeMass'].toString())),
              if (review['storageMass'] != null)
                _Row('Storage mass (normalized)',
                    formatEnglishDecimal(review['storageMass'].toString())),
              if (review['storageMassTarget'] != null)
                _Row(
                    'Safe storage target',
                    formatEnglishDecimal(
                        review['storageMassTarget'].toString())),
              _Row('Transient mass (normalized)',
                  formatEnglishDecimal(review['transientMass'].toString())),
              _Row('Fee mass',
                  formatEnglishDecimal(review['feeMass'].toString())),
              _Row('Compute budget', review['computeBudget'].toString()),
            ]),
            if (_isPlan)
              for (final item in (review['steps'] as List).asMap().entries)
                ExpansionTile(
                  title: Text(
                      '${item.key + 1}. ${item.key + 1 == _remaining ? 'Recipient payment' : 'Self-consolidation'}'),
                  subtitle: Text(
                      '${formatSompi(((item.value as Map)['feeSompi'] as num).toInt())} KAS network fee'),
                  children: [
                    _Row('Transaction ID',
                        (item.value as Map)['transactionId'].toString()),
                    _Row(
                        'Recipient',
                        (((item.value as Map)['psktRequest']
                                as Map)['tradeSummary'] as Map)['recipient']
                            .toString()),
                    _Row(
                        'Raw amount',
                        (((item.value as Map)['psktRequest']
                                as Map)['tradeSummary'] as Map)['amount']
                            .toString()),
                    _Row('Token inputs',
                        (item.value as Map)['covenantInputCount'].toString()),
                    _Row('KAS reserve top-up',
                        '${formatSompi(((item.value as Map)['lockedKasTopUpSompi'] as num).toInt())} KAS'),
                    _Row('KAS released',
                        '${formatSompi(((item.value as Map)['lockedKasReleasedSompi'] as num).toInt())} KAS'),
                  ],
                ),
            if ((review['lockedKasTopUpSompi'] as num?)?.toInt() != 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'The reserve top-up adds only the KAS needed to keep the new token cells spendable. It is not a network fee.',
                  style: TextStyle(color: Color(0xFFFFC857)),
                ),
              ),
            if ((review['lockedKasReleasedSompi'] as num?)?.toInt() != 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Excess KAS from the consumed token cells returns as normal wallet change.',
                  style: TextStyle(color: KasVaultTheme.mint),
                ),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child:
                    Text(status!, style: TextStyle(color: KasVaultTheme.mint)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(error!,
                    style: const TextStyle(color: Color(0xFFFF8A65))),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: working || (_needsAcknowledgement && !_acknowledged)
                  ? null
                  : onConfirm,
              icon: const Icon(Icons.send_rounded),
              label: Text(buttonLabel(
                working
                    ? 'SENDING ON-CHAIN…'
                    : _isPlan
                        ? 'AUTHORIZE COMPLETE PAYMENT PLAN'
                        : 'SEND ON-CHAIN',
              )),
            ),
            TextButton(
              onPressed: working ? null : onCancel,
              child: Text(buttonLabel('CANCEL')),
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
        Text(displayLabel('REVIEW ASSET TRANSFER'),
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
        Hub21Readable(
            child: const Text(
                'The 0.3 KAS commit is returned to your wallet by the reveal transaction, minus its network fee. A saved pending transfer can be resumed.',
                style: TextStyle(color: KasVaultTheme.muted))),
        if (status != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child:
                  Text(status!, style: TextStyle(color: KasVaultTheme.mint))),
        const SizedBox(height: 20),
        FilledButton(
            onPressed: working ? null : onConfirm,
            child: Text(buttonLabel(
              working ? 'WORKING…' : 'AUTHORIZE COMMIT + REVEAL',
            ))),
        TextButton(
            onPressed: working ? null : onCancel,
            child: Text(buttonLabel('CANCEL'))),
      ]));
}

class _TransferFact extends StatelessWidget {
  const _TransferFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: KasVaultTheme.detailText),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      );
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
        Icon(Icons.sync_rounded, size: 58, color: KasVaultTheme.mint),
        const SizedBox(height: 15),
        Text(displayLabel('TRANSFER COMMIT SAVED'),
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
            label: Text(
              buttonLabel(working ? 'CHECKING…' : 'RESUME REVEAL'),
            )),
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
      Icon(Icons.check_circle_rounded, size: 70, color: KasVaultTheme.mint),
      Text(displayLabel('ASSET SENT'),
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
        label: Text(buttonLabel('SEND ANOTHER ASSET')),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: onDone,
        child: Text(buttonLabel('BACK TO WALLET')),
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
      decoration: KasVaultTheme.isDecorative
          ? kaspireDecorativeDecoration(radius: 18, rim: 2.5)
          : BoxDecoration(
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
        Text(label, style: TextStyle(color: KasVaultTheme.detailText)),
        const SizedBox(width: 12),
        Expanded(
            child: SelectableText(value,
                textAlign: TextAlign.right,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))
      ]));
}
