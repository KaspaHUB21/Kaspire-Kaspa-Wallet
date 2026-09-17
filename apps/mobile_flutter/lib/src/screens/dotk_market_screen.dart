import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dotk_market_service.dart';
import '../services/dotk_service.dart';
import '../services/network_settings.dart';
import '../services/native_security.dart';
import '../services/app_settings.dart';
import '../number_format.dart';
import '../widgets/hub21_material.dart';

String marketKas(Object? value) =>
    '${formatRawTokenAmount(BigInt.parse(value.toString()), 8)} KAS';

class DotkListedAssets extends StatefulWidget {
  const DotkListedAssets({super.key, required this.address});
  final String address;
  @override
  State<DotkListedAssets> createState() => _DotkListedAssetsState();
}

class _DotkListedAssetsState extends State<DotkListedAssets> {
  final _service = DotkMarketService();
  late Future<List<DotkOffer>> _listings;
  Future<List<DotkOffer>> _load() async {
    final entries = await _service.saved(widget.address);
    final active = <DotkOffer>[];
    for (final offer in entries) {
      try {
        await _service.verifiedCells(offer);
        active.add(offer);
      } catch (_) {
        // Never label a pending/spent/unverified name as an active listing.
      }
    }
    active.sort((a, b) => a.name.compareTo(b.name));
    return active;
  }

  void _refresh() {
    if (mounted) setState(() => _listings = _load());
  }

  @override
  void initState() {
    super.initState();
    _listings = _load();
    DotkMarketService.changes.addListener(_refresh);
  }

  @override
  void didUpdateWidget(DotkListedAssets oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.address != widget.address) _listings = _load();
  }

  @override
  void dispose() {
    DotkMarketService.changes.removeListener(_refresh);
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DotkOffer>>(
      future: _listings,
      builder: (context, snapshot) =>
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final offer in snapshot.data ?? <DotkOffer>[])
              ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(offer.name),
                  subtitle: const Text('Listed · locked in sale covenant'),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) =>
                            DotkMarketScreen(address: widget.address)));
                    _refresh();
                  }),
          ]));
}

class DotkMarketScreen extends StatefulWidget {
  const DotkMarketScreen({super.key, required this.address, this.service});
  final String address;
  final DotkMarketService? service;
  @override
  State<DotkMarketScreen> createState() => _DotkMarketScreenState();
}

class _DotkMarketScreenState extends State<DotkMarketScreen> {
  late final _service = widget.service ?? DotkMarketService();
  final _search = TextEditingController();
  List<DotkOffer> _offers = [], _saved = [];
  List<DotkName> _names = [];
  bool _busy = false;
  bool _loading = false;
  bool _namesLoading = true;
  bool _priceDescending = false;
  Map<String, DotkOfferStatus> _statuses = {};
  Set<String> _published = {};
  final Set<String> _publishing = {};
  String? _error;
  int _tab = 0;
  int _limit = 12;
  int _generation = 0;
  bool _verifying = false;
  List<DotkOffer> get _page => (_tab == 2
          ? sortMyMarketOffers(_saved, _statuses)
          : sortMarketOffers(_visibleOffers, descending: _priceDescending))
      .take(_limit)
      .toList();

  void _selectionChanged(VoidCallback change) {
    setState(() {
      change();
      _limit = 12;
    });
    unawaited(_verifyVisible());
  }

  Future<void> _verifyVisible() async {
    if (_verifying || _loading || _busy || !mounted || _tab == 1) return;
    _verifying = true;
    final generation = _generation;
    try {
      while (mounted &&
          !_busy &&
          !_loading &&
          generation == _generation &&
          _tab != 1) {
        final pending = _page
            .where((o) => !_statuses.containsKey(o.listingTxId))
            .take(2)
            .toList();
        if (pending.isEmpty) break;
        await Future.wait(pending.map((offer) async {
          final status = await _service.status(offer);
          if (!mounted || generation != _generation || _busy) return;
          setState(() {
            _statuses[offer.listingTxId] = status;
            if ([DotkOfferState.sold, DotkOfferState.cancelled]
                .contains(status.state)) {
              _offers.removeWhere((o) => o.listingTxId == offer.listingTxId);
            }
          });
        }));
      }
    } finally {
      _verifying = false;
      if (mounted && generation != _generation) unawaited(_verifyVisible());
    }
  }

  Future<void> _loadNames(int generation) async {
    try {
      final names = await _service.namesOf(widget.address);
      if (mounted && generation == _generation) setState(() => _names = names);
    } catch (_) {/* Holdings must never block Browse. */} finally {
      if (mounted && generation == _generation) {
        setState(() => _namesLoading = false);
      }
    }
  }

  List<DotkOffer> get _visibleOffers => _offers
      .where((o) => o.name.contains(_search.text.trim().toLowerCase()))
      .toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (_busy || _loading) return;
    setState(() {
      _loading = true;
      _namesLoading = true;
      _generation++;
      _statuses = {};
      if (!quiet) _error = null;
    });
    unawaited(_loadNames(_generation));
    try {
      final saved = await _service.saved(widget.address);
      if (mounted) setState(() => _saved = saved);
      List<DotkOffer> offers = _offers;
      try {
        // Fetch the directory independently of the Browse query, so a search
        // cannot turn an already published entry back into a Publish action.
        offers = await _service.search('');
        if (mounted) {
          setState(() {
            _published = offers.map((o) => o.listingTxId).toSet();
            _offers = List.of(offers);
          });
        }
      } catch (e) {
        if (mounted && !quiet) setState(() => _error = e.toString());
      }
      // Restore the seller's listing terms even after an app reinstall.
      for (final offer in offers.where((o) => o.seller == widget.address)) {
        await _service.save(offer);
      }
      final restored = await _service.saved(widget.address);
      if (mounted) {
        setState(() {
          _saved = restored;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
      if (mounted) unawaited(_verifyVisible());
    }
  }

  Future<void> _import() async {
    final input = TextEditingController();
    final text = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Restore listing recovery code'),
              content: TextField(
                  controller: input,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText:
                          'Listing JSON — never enter a seed or private key')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, input.text),
                    child: const Text('Restore'))
              ],
            ));
    input.dispose();
    if (text == null) return;
    try {
      if (text.length > 8192) {
        throw const FormatException('Recovery code too large');
      }
      final offer = DotkOffer.fromJson(jsonDecode(text));
      if (offer.seller != widget.address) {
        throw StateError(
            'Select the selling wallet before restoring this listing.');
      }
      await _service.verifiedCells(offer);
      await _service.save(offer);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _list(DotkName name) async {
    final price = TextEditingController();
    final amount = await showDialog<int>(
        context: context,
        builder: (context) => StatefulBuilder(builder: (context, update) {
              int? value;
              final text = price.text;
              if (RegExp(r'^\d+(?:\.\d{0,8})?$').hasMatch(text)) {
                final parts = text.split('.');
                value = int.tryParse(parts[0] +
                    (parts.length > 1 ? parts[1] : '').padRight(8, '0'));
              }
              final valid = value != null &&
                  value >= 1000000000 &&
                  value <= 9000000000000000;
              return AlertDialog(
                  title: Text('List ${name.name}'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'The name will be locked in a sale covenant. You receive 97.9% of the price. Listing and cancellation cost a network fee. A separate 1 KAS sale reserve is returned to you on sale or cancellation.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: price,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          TextInputFormatter.withFunction(
                              (oldValue, newValue) =>
                                  RegExp(r'^\d*(?:\.\d{0,8})?$')
                                          .hasMatch(newValue.text)
                                      ? newValue
                                      : oldValue)
                        ],
                        decoration: const InputDecoration(
                            labelText: 'Gross price in KAS',
                            helperText: 'Marketplace minimum: 10 KAS'),
                        onChanged: (_) => update(() {})),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed:
                            valid ? () => Navigator.pop(context, value) : null,
                        child: const Text('Review listing'))
                  ]);
            }));
    price.dispose();
    if (amount == null) return;
    await _run(
        () => _service.listingRequest(widget.address, name.name, amount));
  }

  Future<void> _run(Future<MarketMap> Function() requestBuilder) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await NativeSecurity().hasNativeWalletFor(widget.address)) {
        throw StateError(
            'A signing wallet is required. Watch wallets cannot list or buy.');
      }
      final request = await requestBuilder();
      final review = await _service.prepare(request);
      if (!mounted) return;
      final proceed = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => _MarketReview(review: review)));
      if (proceed != true || !mounted) return;
      final signed = await _service.sign(request, review);
      if (!mounted) return;
      if (request['action'] == 'list') {
        final offer = DotkOffer(
            terms: (request['terms'] as Map).cast<String, Object?>(),
            listingTxId: signed['transactionId'] as String,
            saleId: review['covenantId'] as String);
        final ready = await _recovery(offer, beforeBroadcast: true);
        if (ready != true) return;
      }
      final id = await _service.broadcast(signed);
      if (!mounted) return;
      var published = false;
      if (request['action'] == 'list') {
        final offer = DotkOffer(
            terms: (request['terms'] as Map).cast<String, Object?>(),
            listingTxId: id,
            saleId: review['covenantId'] as String);
        for (var attempt = 0; attempt < 3; attempt++) {
          if (!mounted) break;
          try {
            await _service.publish(offer);
            if (mounted) setState(() => _published.add(offer.listingTxId));
            published = true;
            break;
          } catch (_) {
            if (attempt < 2) {
              await Future<void>.delayed(const Duration(seconds: 2));
            }
          }
        }
      } else {
        setState(
            () => _offers.removeWhere((o) => o.saleId == review['covenantId']));
      }
      if (!mounted) return;
      if (request['action'] == 'list' && !published) {
        setState(() {
          _tab = 2;
          _error =
              'Offer not published: tap Publish under My listings to make it visible in Browse.';
        });
      }
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(request['action'] == 'list'
                    ? published
                        ? 'Listed for sale'
                        : 'Publication needs attention'
                    : 'Transaction submitted'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(published
                      ? 'Your name is listed in Browse. No further action is required.'
                      : request['action'] == 'list'
                          ? 'Your name is locked in the sale covenant, but the offer is NOT visible in Browse yet. Open My listings and tap Publish after confirmation. Do not create another listing.'
                          : 'Submitted to the node. The marketplace refreshes when you close this message. Use Refresh if confirmation is still pending.'),
                  const SizedBox(height: 12),
                  SelectableText(id),
                ])),
                actions: [
                  TextButton(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: id)),
                      child: const Text('Copy ID')),
                  FilledButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: Text(request['action'] == 'list' && !published
                          ? 'Open My listings'
                          : 'Done'))
                ],
              ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        final saved = await _service.saved(widget.address);
        if (mounted) {
          setState(() {
            _saved = saved;
            _busy = false;
          });
          await _load(quiet: true);
        }
      }
    }
  }

  Future<bool?> _recovery(DotkOffer offer, {bool beforeBroadcast = false}) =>
      showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(builder: (context, update) {
                return AlertDialog(
                    title: const Text('Save listing recovery code'),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Text(
                              'Keep this public listing code alongside your wallet backup. Together with your wallet it lets you cancel if the marketplace directory is unavailable. It contains no private key. The name is not locked until you submit.'),
                          const SizedBox(height: 12),
                          SelectableText(jsonEncode(offer.toJson()),
                              style: const TextStyle(fontSize: 11)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Clipboard.setData(
                              ClipboardData(text: jsonEncode(offer.toJson()))),
                          child: const Text('Copy recovery code')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Close')),
                      if (beforeBroadcast)
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Saved — submit listing')),
                    ]);
              }));

  Widget _offer(DotkOffer offer, {bool mine = false}) {
    final status = _statuses[offer.listingTxId];
    final active = status?.state == DotkOfferState.active;
    final terminal =
        [DotkOfferState.sold, DotkOfferState.cancelled].contains(status?.state);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(offer.name,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(marketKas(offer.terms['priceSompi'])),
                  Text(status?.label ?? 'Checking listing…'),
                  if (status?.transactionId != null)
                    SelectableText('Transaction: ${status!.transactionId}'),
                  if (mine) ...[
                    Wrap(spacing: 8, children: [
                      if (!terminal)
                        TextButton(
                            onPressed: _busy ? null : () => _recovery(offer),
                            child: const Text('Recovery code')),
                      if (!terminal)
                        TextButton(
                            onPressed: _busy ||
                                    _published.contains(offer.listingTxId) ||
                                    _publishing.contains(offer.listingTxId)
                                ? null
                                : () async {
                                    setState(() =>
                                        _publishing.add(offer.listingTxId));
                                    try {
                                      await _service.publish(offer);
                                      if (mounted) {
                                        setState(() =>
                                            _published.add(offer.listingTxId));
                                      }
                                      await _load();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(const SnackBar(
                                                content:
                                                    Text('Offer published')));
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        setState(() => _error = e.toString());
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _publishing
                                            .remove(offer.listingTxId));
                                      }
                                    }
                                  },
                            child: Text(_published.contains(offer.listingTxId)
                                ? 'Published'
                                : _publishing.contains(offer.listingTxId)
                                    ? 'Publishing…'
                                    : 'Publish')),
                      if (!terminal)
                        OutlinedButton(
                            onPressed: _busy || !active
                                ? null
                                : () => _run(() => _service.spendingRequest(
                                    widget.address, offer,
                                    cancel: true)),
                            child: Text(buttonLabel('CANCEL LISTING'))),
                    ]),
                  ] else
                    FilledButton.icon(
                        onPressed: _busy || !active
                            ? null
                            : () => _run(() => _service.spendingRequest(
                                widget.address, offer,
                                cancel: false)),
                        icon: const Icon(Icons.shopping_bag_outlined),
                        label: Text(buttonLabel('REVIEW PURCHASE'))),
                ])));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('dot.k Marketplace'), actions: [
        IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
              children: [
            SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Browse')),
                  ButtonSegment(value: 1, label: Text('My names')),
                  ButtonSegment(value: 2, label: Text('My listings'))
                ],
                selected: {
                  _tab
                },
                onSelectionChanged: _busy
                    ? null
                    : (value) => _selectionChanged(() => _tab = value.single)),
            const SizedBox(height: 16),
            if (_busy || _loading) const LinearProgressIndicator(),
            if (_error != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(_error!))),
            if (NetworkSettings.network.value != KaspaNetwork.mainnet)
              const Card(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child:
                          Text('Switch to Layer 1 to use the marketplace.'))),
            if (_tab == 0) ...[
              TextField(
                  controller: _search,
                  decoration: InputDecoration(
                      labelText: 'Search dot.k names',
                      suffixIcon: IconButton(
                          onPressed: _busy ? null : _load,
                          icon: const Icon(Icons.search))),
                  onChanged: (_) => _selectionChanged(() {}),
                  onSubmitted: (_) => _selectionChanged(() {})),
              if (_visibleOffers.isEmpty && !_busy && !_loading)
                const ListTile(title: Text('No offers found')),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                  initialValue: _priceDescending,
                  decoration: const InputDecoration(labelText: 'Sort offers'),
                  items: const [
                    DropdownMenuItem(
                        value: false, child: Text('Price: Low to High')),
                    DropdownMenuItem(
                        value: true, child: Text('Price: High to Low')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _selectionChanged(() => _priceDescending = value);
                    }
                  }),
              ..._page.map((o) => _offer(o, mine: o.seller == widget.address)),
            ],
            if (_tab == 1) ...[
              if (_namesLoading) const LinearProgressIndicator(),
              if (_names.isEmpty && !_busy && !_namesLoading)
                const ListTile(
                    title: Text('No dot.k names found for this address')),
              ..._names.map((n) => Card(
                  child: ListTile(
                      leading: const Icon(Icons.alternate_email),
                      title: Text(n.name),
                      trailing: OutlinedButton(
                          onPressed: _busy ? null : () => _list(n),
                          child: const Text('List for sale'))))),
            ],
            if (_tab == 2) ...[
              OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore listing recovery code')),
              const Hub21Readable(
                  child: Text(
                      'Cancel a listing first to change its price. Once cancellation is confirmed, refresh My names and list again. Recovery entries stay on this device even after a sale or cancellation.')),
              ..._page.map((o) => _offer(o, mine: true)),
            ],
            if ((_tab == 0 && _visibleOffers.length > _limit) ||
                (_tab == 2 && _saved.length > _limit))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _limit += 12);
                          unawaited(_verifyVisible());
                        },
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Load more'),
                ),
              ),
          ])));
}

class _MarketReview extends StatelessWidget {
  const _MarketReview({required this.review});
  final MarketMap review;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('Review ${review['action']}')),
      body: SafeArea(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
              children: [
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(review['name'] as String,
                              style: Theme.of(context).textTheme.headlineSmall),
                          for (final field in {
                            'priceSompi': 'Gross sale price',
                            'sellerNetSompi': 'Seller proceeds on purchase',
                            'marketplaceFeeSompi':
                                'Marketplace fee on purchase (2.1%)',
                            'saleReserveSompi':
                                'Sale reserve (returned to seller)',
                            'deedBondSompi':
                                'Existing name bond (stays with name)',
                            'feeSompi': 'Network fee for this transaction',
                            'changeSompi': 'Your KAS change'
                          }.entries)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(field.value),
                                      Text(marketKas(review[field.key]),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold))
                                    ])),
                          for (final field in {
                            'sender': 'Signing account',
                            'seller': 'Seller',
                            'feeAddress':
                                'Fee recipient — pinned from hub21.kas',
                            'covenantId': 'Sale covenant ID',
                            'mass': 'Effective mass',
                            'reviewHash': 'Native review hash'
                          }.entries) ...[
                            const SizedBox(height: 12),
                            Text(field.value),
                            SelectableText('${review[field.key]}'),
                          ],
                        ]))),
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'The sale reserve is not a fee. Listing locks the name on-chain. A sale and a cancellation can race; only one can succeed. Never send payments directly to the deed or sale address.'))),
            Card(
                child: ExpansionTile(
                    title: const Text('Raw transaction JSON (unsigned)'),
                    children: [
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(
                              jsonDecode(review['transactionJson'] as String)),
                          style: const TextStyle(fontSize: 11)))
                ])),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.verified_user_outlined),
                label: Text(buttonLabel('AUTHORIZE TRANSACTION'))),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
          ])));
}
