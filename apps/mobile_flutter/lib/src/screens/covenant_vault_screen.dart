import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../kaspa_address.dart';
import '../number_format.dart';
import '../services/covenant_vault_service.dart';
import '../widgets/hub21_material.dart';
import '../widgets/cascoven_vault_header.dart';
import '../platform.dart';

String vaultKas(Object? amount) =>
    '${formatRawTokenAmount(BigInt.from(vaultInt(amount)), 8)} KAS';
int parseVaultKas(String text) {
  final value = text.trim();
  if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(value)) {
    throw StateError('Enter a KAS amount with at most 8 decimal places.');
  }
  final parts = value.split('.');
  final raw = BigInt.parse(parts[0]) * BigInt.from(100000000) +
      BigInt.parse(parts.length == 1 ? '0' : parts[1].padRight(8, '0'));
  if (raw < BigInt.from(100000000) ||
      raw > BigInt.parse('2870000000000000000')) {
    throw StateError('Vault amount must be at least 1 KAS.');
  }
  return raw.toInt();
}

class CovenantVaultScreen extends StatefulWidget {
  const CovenantVaultScreen({super.key, required this.address, this.service});
  final String address;
  final CovenantVaultService? service;
  @override
  State<CovenantVaultScreen> createState() => _CovenantVaultScreenState();
}

class _CovenantVaultScreenState extends State<CovenantVaultScreen> {
  late final CovenantVaultService _service =
      widget.service ?? CovenantVaultService();
  final _name = TextEditingController(),
      _amount = TextEditingController(text: '1'),
      _beneficiary = TextEditingController(),
      _limit = TextEditingController();
  List<Map<String, Object?>> _items = [];
  // Only hide confirmed completed vaults from the overview. Keep the durable
  // catalog intact for recovery and any incomplete transaction visible.
  List<Map<String, Object?>> get _overviewItems => _items
      .where((item) =>
          vaultMap(item['record'])['status'] != 'opened' ||
          item['pending'] != null)
      .toList();
  String? _kind, _selected, _error;
  Map<String, Object?>? _prepared;
  bool _busy = false;
  int _daa = 0, _duration = 864000;
  Timer? _clock, _confirmationClock;
  DateTime _daaAt = DateTime.now();
  int get _estimatedDaa => _daa == 0
      ? 0
      : _daa + DateTime.now().difference(_daaAt).inMilliseconds ~/ 100;
  Map<String, Object?>? get _item {
    for (final item in _items) {
      if (vaultMap(item['record'])['covenantId'] == _selected) return item;
    }
    return null;
  }

  bool _needsNodeCheck(Map<String, Object?> item) =>
      item['pending'] != null ||
      vaultMap(item['record'])['status'] == 'pending';

  String _status(Map<String, Object?> item) => item['pending'] != null
      ? vaultMap(item['pending'])['submitted'] == true
          ? 'Awaiting confirmation'
          : 'Transaction incomplete'
      : vaultMap(item['record'])['status'] == 'pending'
          ? 'Checking vault state'
          : '${vaultMap(item['record'])['status']}';

  @override
  void initState() {
    super.initState();
    _load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _confirmationClock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && _items.any(_needsNodeCheck)) {
        _checkPending();
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _confirmationClock?.cancel();
    _name.dispose();
    _amount.dispose();
    _beneficiary.dispose();
    _limit.dispose();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  String message(Object e) => e is PlatformException
      ? e.message ?? e.code
      : e.toString().replaceFirst('Bad state: ', '');
  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      // Signing may have succeeded before the network failed. Surface the
      // durable journal immediately instead of inviting a second deposit.
      try {
        _items = await _service.saved();
      } catch (_) {/* Keep known records. */}
      if (mounted) setState(() => _error = message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
        // Local recovery records appear immediately, even if the node is offline.
        final items = await _service.saved();
        if (mounted) setState(() => _items = items);
        for (var i = 0; i < items.length; i++) {
          if (_needsNodeCheck(items[i])) {
            items[i] = await _service.refresh(items[i]);
          }
        }
        if (mounted) setState(() => _items = items);
        final score = await _service.daa();
        if (mounted) {
          setState(() {
            _daa = score;
            _daaAt = DateTime.now();
          });
        }
      });
  Future<void> _checkPending() => _run(() async {
        final items = await _service.saved();
        for (var i = 0; i < items.length; i++) {
          if (!mounted) return;
          if (_needsNodeCheck(items[i])) {
            items[i] = await _service.refresh(items[i]);
          }
        }
        if (mounted) setState(() => _items = items);
      });
  void _home() => setState(() {
        _kind = null;
        _selected = null;
        _prepared = null;
        _error = null;
      });
  Future<void> _refresh() => _run(() async {
        final items = await _service.saved();
        final failures = <String>[];
        for (var i = 0; i < items.length; i++) {
          try {
            items[i] = await _service.refresh(items[i]);
          } catch (e) {
            failures.add(message(e));
          }
        }
        if (mounted) setState(() => _items = items);
        final score = await _service.daa();
        if (mounted) {
          setState(() {
            _daa = score;
            _daaAt = DateTime.now();
          });
        }
        if (failures.isNotEmpty) throw StateError(failures.first);
      });
  void _start(String kind) {
    setState(() {
      _kind = kind;
      _selected = null;
      _prepared = null;
      _error = null;
      _name.text =
          kind == 'timeLock' ? 'Time-Locked Vault' : "Dead Man’s Switch";
      _limit.text = '${_estimatedDaa + _duration}';
    });
  }

  Future<void> _prepare() => _run(() async {
        final current = await _service.daa();
        final deadline = int.tryParse(_limit.text.trim());
        if (deadline == null || deadline <= current) {
          throw StateError('Choose an unlock DAA score in the future.');
        }
        final beneficiary = _beneficiary.text.trim();
        if (_kind == 'deadManSwitch' &&
            (!beneficiary.startsWith('kaspa:') ||
                kaspaOwnerIdFromAddress(beneficiary).isEmpty)) {
          throw StateError(
              'Paste a complete valid mainnet Kaspa beneficiary address.');
        }
        final terms = _service.terms(
            owner: widget.address,
            kind: _kind!,
            name: _name.text,
            limitDaa: _kind == 'timeLock' ? deadline : deadline - current,
            beneficiary: _kind == 'deadManSwitch' ? beneficiary : '');
        final prepared = await _service.prepare(
            widget.address, terms, parseVaultKas(_amount.text), 'create');
        if (mounted) {
          setState(() {
            _prepared = prepared;
            _daa = current;
            _daaAt = DateTime.now();
          });
        }
      });
  Future<void> _success(String title, String text,
          {String button = 'Return to vaults'}) =>
      showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
                  title: Text(title),
                  content: SingleChildScrollView(child: SelectableText(text)),
                  actions: [
                    TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          if (button == 'Return to vaults') _home();
                        },
                        child: Text(button))
                  ]));
  Future<void> _finishTransaction(String id, {String? recoveryPath}) async {
    // Keep the user in the transaction flow until our own node confirms it.
    // A missing/offline node never turns a submitted transaction into success.
    _items = await _service.saved();
    for (var attempt = 0; attempt < 8 && mounted; attempt++) {
      final item = _item;
      if (item == null || item['pending'] == null) break;
      try {
        await _service.refresh(item);
        _items = await _service.saved();
        if (mounted) setState(() {});
      } catch (e) {
        if (mounted) setState(() => _error = message(e));
        break;
      }
      if (_item?['pending'] == null) break;
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (!mounted) return;
    if (_item == null || _item!['pending'] != null) {
      await _success('Transaction not yet confirmed',
          'The signed transaction is safely saved, but vault creation or the requested action is NOT complete yet. Kaspire will keep checking automatically. Do not create a replacement vault. If needed, retry only this saved transaction.\n\nTransaction ID\n$id',
          button: 'View pending vault');
      return;
    }
    await _success('Vault transaction confirmed',
        'The Kaspire node confirmed the transaction.\n\nTransaction ID\n$id${recoveryPath == null ? '' : '\n\nRecovery file saved\n$recoveryPath\n\nKeep the recovery file and password safe.'}');
  }

  Future<void> _create() => _run(() async {
        final prepared = _prepared!;
        // Require portable recovery before funding, without ever exporting wallet keys.
        final path = await _service.security.exportVaultRecovery(
            vaultMap(vaultMap(prepared['review'])['record']));
        if (path == null || !mounted) return;
        setState(() {
          _selected =
              vaultMap(vaultMap(prepared['review'])['record'])['covenantId']
                  .toString();
          _kind = null;
        });
        final id = await _service.commit(prepared);
        _items = await _service.saved();
        if (!mounted) return;
        setState(() {
          _selected =
              vaultMap(vaultMap(prepared['review'])['record'])['covenantId']
                  .toString();
          _kind = null;
          _prepared = null;
        });
        await _finishTransaction(id, recoveryPath: path);
      });
  Future<void> _reviewAction(String action) => _run(() async {
        final item = _item!, record = vaultMap(item['record']);
        if (item['pending'] != null) {
          throw StateError(
              'A signed vault transaction is already saved. Resume or refresh it first.');
        }
        final prepared = await _service.prepare(widget.address,
            vaultMap(record['terms']), vaultInt(record['amountSompi']), action,
            record: record);
        if (!mounted) return;
        final approved = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: Text(
                        action == 'heartbeat' ? 'Owner Pulse' : 'Open Vault'),
                    content: SingleChildScrollView(
                        child: _review(vaultMap(prepared['review']))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign & broadcast'))
                    ]));
        if (approved != true || !mounted) return;
        final id = await _service.commit(prepared, previous: record);
        _items = await _service.saved();
        if (mounted) {
          setState(() {});
          await _finishTransaction(id);
        }
      });
  Future<void> _export() => _run(() async {
        final path = await _service.security
            .exportVaultRecovery(vaultMap(_item!['record']));
        if (path != null && mounted) {
          await _success('Recovery file saved',
              '$path\n\nProtected with Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. Keep this file and a strong password safe. No seed or private key is included.',
              button: 'Back to vault');
        }
      });
  Future<void> _import() => _run(() async {
        final record = await _service.security.importVaultRecovery();
        if (record == null) return;
        await _service.importRecord(record);
        _items = await _service.saved();
        if (mounted) {
          setState(() {
            _kind = null;
            _selected = record['covenantId'].toString();
          });
          await _success('Vault recovery imported',
              'Vault data restored. Refresh to check its current on-chain state. Only the owner or beneficiary wallet can authorize the corresponding actions.');
        }
      });
  Future<void> _scan() => _run(() async {
        final count = await _service.discover(widget.address);
        _items = await _service.saved();
        if (mounted) {
          setState(() {});
          await _success('DAG scan completed',
              '$count new vault record${count == 1 ? '' : 's'} restored. Existing records were preserved.');
        }
      });
  Future<void> _resume() => _run(() async {
        final id = await _service.resume(_item!);
        _items = await _service.saved();
        if (mounted) {
          setState(() {});
          await _finishTransaction(id);
        }
      });
  Widget _panel(List<Widget> children) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children)));
  Widget _line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value, style: Theme.of(context).textTheme.bodyLarge)
      ]));
  Widget _button(String label, IconData icon, VoidCallback action,
          {Key? key}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: FilledButton.icon(
              key: key,
              onPressed: _busy ? null : action,
              icon: Icon(icon),
              label: Text(label),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48))));
  Widget _review(Map<String, Object?> review) {
    final terms = vaultMap(review['terms']);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _line('Vault', terms['name'].toString()),
          _line('Action', review['action'].toString()),
          _line('Amount', vaultKas(review['amountSompi'])),
          _line('Network fee', vaultKas(review['feeSompi'])),
          if (review['action'] == 'create' && terms['kind'] == 'deadManSwitch')
            _line('Beneficiary discovery notice',
                '${vaultKas(review['beneficiaryNoticeSompi'])}, paid to the beneficiary (not a fee)'),
          _line(
              terms['kind'] == 'timeLock'
                  ? 'Unlock DAA'
                  : 'Inactivity duration (DAA)',
              '${terms['limitDaa']}'),
          _line('Owner', '${terms['owner']}'),
          if ('${terms['beneficiary']}'.isNotEmpty)
            _line('Beneficiary', '${terms['beneficiary']}'),
          _line('Recipient', '${review['recipient']}'),
          _line('Covenant ID', '${review['covenantId']}'),
          if (review['action'] == 'heartbeat')
            const Text(
                'The full vault balance is preserved. The owner pays the network fee from a separate KAS output.'),
          if (terms['kind'] == 'timeLock')
            const Text(
                'There is no early cancellation. The on-chain DAA score, not the estimated date, determines when funds can be released.'),
        ]);
  }

  Widget _pendingNotice(Map<String, Object?> item) {
    final submitted = vaultMap(item['pending'])['submitted'] == true;
    return Semantics(
        liveRegion: true,
        child: _panel([
          Row(children: [
            Icon(Icons.pending_actions,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 10),
            Expanded(
                child: Text(
                    submitted
                        ? 'Awaiting node confirmation'
                        : 'Action required · Transaction incomplete',
                    style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 12),
          Text(submitted
              ? 'The transaction was submitted, but is not confirmed yet. Kaspire checks automatically. Do not create a replacement vault.'
              : 'A signed transaction is saved. Vault creation or the requested action is NOT complete. Retry this exact transaction; do not create a second vault.'),
          _button('Resume saved transaction', Icons.refresh, () {
            setState(() =>
                _selected = vaultMap(item['record'])['covenantId'].toString());
            _resume();
          }),
        ]));
  }

  Widget _type(String kind, String title, String text, String image) => _panel([
        ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(image, height: 160, fit: BoxFit.cover)),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(text),
        _button('Start', Icons.arrow_forward, () => _start(kind),
            key: ValueKey('start-$kind')),
      ]);
  List<Widget> _createForm() => [
        _panel([
          Text(_kind == 'timeLock' ? 'Time-Locked Vault' : 'Dead Man’s Switch',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Vault name'),
              onChanged: (_) => setState(() => _prepared = null)),
          const SizedBox(height: 12),
          TextField(
              controller: _amount,
              enabled: !_busy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Amount in KAS', suffixText: 'KAS'),
              onChanged: (_) => setState(() => _prepared = null)),
          if (_kind == 'deadManSwitch') ...[
            const SizedBox(height: 12),
            TextField(
                controller: _beneficiary,
                enabled: !_busy,
                decoration: const InputDecoration(
                    labelText: 'Beneficiary Kaspa address'),
                onChanged: (_) => setState(() => _prepared = null))
          ],
          _line('Current DAA score (last node check)', '$_daa'),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _duration,
              decoration: const InputDecoration(labelText: 'Duration estimate'),
              items: [
                DropdownMenuItem(
                    value: 1200,
                    child: Text(isWindowsDesktop
                        ? '2 minutes'
                        : '2 minutes (internal test)')),
                DropdownMenuItem(value: 36000, child: Text('1 hour')),
                DropdownMenuItem(value: 864000, child: Text('1 day')),
                DropdownMenuItem(value: 6048000, child: Text('7 days')),
                DropdownMenuItem(value: 25920000, child: Text('30 days')),
                DropdownMenuItem(value: 315360000, child: Text('1 year'))
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) {
                        setState(() {
                          _duration = v;
                          _limit.text = '${_estimatedDaa + v}';
                          _prepared = null;
                        });
                      }
                    }),
          const SizedBox(height: 12),
          TextField(
              controller: _limit,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Initial unlock DAA score'),
              onChanged: (_) => setState(() => _prepared = null)),
          const SizedBox(height: 12),
          Text(_kind == 'timeLock'
              ? 'Funds stay locked until this DAA score. The owner is the fixed payout recipient.'
              : 'The owner can pulse at any time. Each confirmed pulse restarts the inactivity duration; the beneficiary can claim only after that duration has elapsed.'),
          _button('Prepare vault', Icons.shield_outlined, _prepare),
        ]),
        if (_prepared != null)
          _panel([
            _review(vaultMap(_prepared!['review'])),
            const SizedBox(height: 12),
            const Text(
                'First save the encrypted recovery file, then approve the wallet signature. Test with a small amount only.'),
            _button(
                'Save recovery · Sign & broadcast', Icons.lock_outline, _create)
          ]),
        _button(
            'Back to vault selection',
            Icons.arrow_back,
            () => setState(() {
                  _kind = null;
                  _prepared = null;
                })),
      ];
  List<Widget> _details(Map<String, Object?> item) {
    final record = vaultMap(item['record']), terms = vaultMap(record['terms']);
    final live = record['lastConfirmedCell'] == null
        ? null
        : vaultMap(record['lastConfirmedCell']);
    final deadline = terms['kind'] == 'timeLock'
        ? vaultInt(terms['limitDaa'])
        : live == null
            ? 0
            : vaultInt(live['blockDaaScore']) + vaultInt(terms['limitDaa']);
    final remaining = deadline == 0
        ? null
        : (deadline - _estimatedDaa).clamp(0, 999999999999) ~/ 10;
    final canOpen = deadline > 0 &&
        _estimatedDaa > deadline &&
        record['status'] == 'locked' &&
        item['pending'] == null;
    final owner = terms['owner'] == widget.address,
        beneficiary = terms['beneficiary'] == widget.address;
    return [
      _panel([
        Text('${terms['name']}', style: Theme.of(context).textTheme.titleLarge),
        _line(
            'Vault type',
            terms['kind'] == 'timeLock'
                ? 'Time-Locked Vault'
                : 'Dead Man’s Switch'),
        _line('Locked amount', vaultKas(record['amountSompi'])),
        _line('Status', _status(item)),
        if (record['status'] != 'opened')
          _line(
              'Estimated countdown',
              remaining == null
                  ? 'Refresh to confirm the vault output'
                  : remaining == 0
                      ? 'Unlock DAA reached — refresh before opening'
                      : '${remaining ~/ 86400}d ${remaining ~/ 3600 % 24}h ${remaining ~/ 60 % 60}m ${remaining % 60}s'),
        const Text(
            'Time estimates assume 10 DAA/s. Consensus and a fresh node check determine spendability.'),
        ExpansionTile(title: const Text('Technical details'), children: [
          _line('Vault address', '${record['vaultAddress']}'),
          _line('Covenant ID', '${record['covenantId']}'),
          _line('Owner', '${terms['owner']}'),
          if ('${terms['beneficiary']}'.isNotEmpty)
            _line('Beneficiary', '${terms['beneficiary']}'),
          _line('Genesis transaction',
              '${record['genesisTransactionId'] ?? record['transactionId']}'),
          _line('Current output transaction', '${record['transactionId']}'),
          _line('Compiler', '${record['compiler']}'),
          _line(terms['kind'] == 'timeLock' ? 'Unlock DAA' : 'Inactivity DAA',
              '${terms['limitDaa']}'),
        ]),
        if (item['pending'] == null) ...[
          if (terms['kind'] == 'deadManSwitch' &&
              owner &&
              record['status'] == 'locked')
            _button('Owner Pulse', Icons.favorite_border,
                () => _reviewAction('heartbeat')),
          if ((terms['kind'] == 'timeLock' && owner) ||
              (terms['kind'] == 'deadManSwitch' && beneficiary))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: FilledButton.icon(
                    onPressed: _busy || !canOpen
                        ? null
                        : () => _reviewAction(
                            terms['kind'] == 'timeLock' ? 'release' : 'claim'),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Open Vault'))),
        ],
        _button('Export recovery', Icons.download_outlined, _export),
        _button('Refresh vaults', Icons.refresh, _refresh),
        _button('Create another vault', Icons.add,
            () => setState(() => _selected = null)),
      ])
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kaspire Covenant Vaults'), actions: [
          IconButton(
              tooltip: 'Vault overview',
              onPressed: _busy ? null : _home,
              icon: const Icon(Icons.home_outlined)),
          IconButton(
              tooltip: 'Refresh',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh))
        ]),
        body: Hub21Backdrop(
            child: SafeArea(
                child: ListView(
                    key: ValueKey('vault-view-${_kind ?? _selected ?? "home"}'),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                    children: [
              if (_kind == null && _item == null)
                ..._items
                    .where((e) => e['pending'] != null)
                    .map(_pendingNotice),
              if (_kind == null && _item != null && _item!['pending'] != null)
                _pendingNotice(_item!),
              const KasCovenVaultHeader(),
              if (_busy)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator()),
              if (_error != null)
                _panel([
                  SelectableText(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const Text('Saved vaults and recovery records are preserved.')
                ]),
              if (_kind != null)
                ..._createForm()
              else if (_item != null)
                ..._details(_item!)
              else ...[
                _panel([
                  Text('My Vaults',
                      style: Theme.of(context).textTheme.titleLarge),
                  if (_overviewItems.isEmpty)
                    Text(_items.isEmpty
                        ? 'No saved vaults yet. Create a vault, import a recovery file, or scan the DAG.'
                        : 'No active vaults. Opened vaults are hidden from this overview.'),
                  ..._overviewItems.map((item) {
                    final r = vaultMap(item['record']),
                        t = vaultMap(r['terms']);
                    return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(t['kind'] == 'timeLock'
                            ? Icons.lock_clock_outlined
                            : Icons.favorite_border),
                        title: Text('${t['name']}'),
                        subtitle: Text(
                            '${vaultKas(r['amountSompi'])} · ${_status(item)}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy
                            ? null
                            : () => setState(
                                () => _selected = r['covenantId'].toString()));
                  }),
                ]),
                _panel([
                  Text('Recovery',
                      style: Theme.of(context).textTheme.titleLarge),
                  const ExpansionTile(
                      title: Text('Post-quantum recovery protection'),
                      children: [
                        Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                                'Vault recovery files use Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. A strong password remains essential.'))
                      ]),
                  _button('Import recovery file', Icons.upload_file, _import),
                  _button(
                      'Scan owner / beneficiary vaults', Icons.search, _scan)
                ]),
                _type(
                    'timeLock',
                    'Time-Locked Vault',
                    'Lock KAS until a chosen DAA score. Release to the fixed owner address after maturity.',
                    'assets/vaults/timelockedvault.png'),
                _type(
                    'deadManSwitch',
                    'Dead Man’s Switch',
                    'Keep control with Owner Pulses. The beneficiary can claim only after the configured inactivity period.',
                    'assets/vaults/deadmansswitch.png'),
              ],
            ]))),
      );
}
