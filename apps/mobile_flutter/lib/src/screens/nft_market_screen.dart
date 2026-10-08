import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nft_market_service.dart';
import '../services/native_security.dart';
import '../number_format.dart';
import '../widgets/hub21_material.dart';
import '../widgets/krc721_image.dart';

String nftKas(Object? amount) =>
    '${formatRawTokenAmount(BigInt.parse(amount.toString()), 8)} KAS';
int? nftPrice(String input) {
  if (!RegExp(r'^\d+(?:\.\d{1,8})?$').hasMatch(input)) return null;
  final pieces = input.split('.');
  final value = BigInt.parse(pieces.first) * BigInt.from(100000000) +
      BigInt.parse((pieces.length > 1 ? pieces[1] : '').padRight(8, '0'));
  if (value < BigInt.from(476191) || value > BigInt.from(9000000000000000)) {
    return null;
  }
  return value.toInt();
}

class NftMarketScreen extends StatefulWidget {
  const NftMarketScreen(
      {super.key,
      required this.address,
      this.initialNft,
      this.initialTab = 0,
      this.service});
  final String address;
  final Map<String, Object?>? initialNft;
  final int initialTab;
  final NftMarketService? service;
  @override
  State<NftMarketScreen> createState() => _NftMarketScreenState();
}

class _NftMarketScreenState extends State<NftMarketScreen> {
  late final service = widget.service ?? NftMarketService();
  final search = TextEditingController();
  List<Map<String, Object?>> offers = [], owned = [], mine = [];
  List<String> collections = [];
  List<String> myCollections = [];
  Map<String, List<String>> options = {};
  Map<String, String> traits = {};
  String? collection, error, cursor;
  String? myCollection;
  int tab = 0, visibleOwned = 10, visibleMine = 10;
  int? nextOffset;
  bool loading = false, busy = false;
  String sort = 'recent';
  bool approvalCancelled = false;
  bool pendingBroadcast = false;
  int generation = 0;
  Timer? debounce;
  Timer? publicationTimer;
  bool retryingPublication = false;

  Future<void> _retryPublication() async {
    if (retryingPublication || busy) return;
    retryingPublication = true;
    final before = NftMarketService.changes.value;
    try {
      final records = await service.saved(widget.address);
      if (!mounted) return;
      if (!records.any((r) =>
          r['stage'] == 'complete' &&
          r['published'] != true &&
          r['publicationBlocked'] != true &&
          !['sold', 'cancelled'].contains(r['status']))) {
        publicationTimer?.cancel();
        publicationTimer = null;
        return;
      }
      publicationTimer ??= Timer.periodic(
          const Duration(seconds: 30), (_) => _retryPublication());
      await service.publishPending(widget.address);
      if (mounted && !busy && before != NftMarketService.changes.value) {
        await _load();
      }
    } finally {
      retryingPublication = false;
    }
  }

  @override
  void initState() {
    super.initState();
    tab = widget.initialTab;
    _load();
    _retryPublication();
    if (widget.initialNft != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _list(widget.initialNft!));
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    publicationTimer?.cancel();
    search.dispose();
    service.close();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (loading && more) return;
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      service.guard();
      final pending = await service.hasPendingBroadcast(widget.address);
      if (!mounted || current != generation) return;
      setState(() => pendingBroadcast = pending);
      if (tab == 0) {
        final data = await service.browse(
            q: search.text.trim(),
            collection: collection,
            traits: traits,
            sort: sort,
            offset: more ? (nextOffset ?? 0) : 0,
            refresh: !more);
        if (!mounted || current != generation) return;
        final page = (data['offers'] as List).map(nftMap).toList();
        setState(() {
          offers = more ? [...offers, ...page] : page;
          nextOffset = (data['nextOffset'] as num?)?.toInt();
          collections = (data['collections'] as List).cast<String>();
          options = nftMap(data['traitOptions'])
              .map((k, v) => MapEntry(k, (v as List).cast<String>()));
        });
      } else if (tab == 1) {
        if (!more && myCollections.isEmpty) {
          myCollections = await service.ownedCollections(widget.address);
        }
        final data = await service.owned(widget.address,
            cursor: more ? cursor : null, collection: myCollection);
        if (!mounted || current != generation) return;
        setState(() {
          owned = more
              ? [...owned, ...(data['items'] as List).map(nftMap)]
              : (data['items'] as List).map(nftMap).toList();
          cursor = data['next'] as String?;
          if (!more) visibleOwned = 10;
        });
      } else {
        final local = await service.saved(widget.address);
        if (more) {
          for (final previous in mine) {
            if (!local.any((r) =>
                r['listingTransactionId'] == previous['listingTransactionId'] &&
                r['localId'] == previous['localId'])) {
              local.add(Map<String, Object?>.of(previous));
            }
          }
        }
        if (!mounted || current != generation) return;
        // Local recovery remains accessible even if the discovery directory is offline.
        setState(() => mine = local);
        final remote = await service.browse(
            seller: widget.address,
            offset: more ? (nextOffset ?? 0) : 0,
            refresh: true);
        if (!mounted || current != generation) return;
        final page = (remote['offers'] as List).map(nftMap).toList();
        for (final r in page) {
          final matches = local.where(
              (l) => l['listingTransactionId'] == r['listingTransactionId']);
          if (matches.isNotEmpty) {
            final l = matches.first;
            l.addAll({
              'status': r['status'],
              'rarityRank': r['rarityRank'] ?? l['rarityRank'],
              if (r['imageUrl'] != null) 'imageUrl': r['imageUrl']
            });
            await service.save(widget.address, l);
          } else {
            local.add(r);
          }
        }
        local.sort((a, b) {
          int order(Map<String, Object?> r) =>
              ['sold', 'cancelled'].contains(r['status']) ? 1 : 0;
          final group = order(a).compareTo(order(b));
          return group != 0
              ? group
              : (b['createdAt'] as num? ?? 0)
                  .compareTo(a['createdAt'] as num? ?? 0);
        });
        if (!mounted || current != generation) return;
        setState(() {
          mine = local;
          nextOffset = (remote['nextOffset'] as num?)?.toInt();
          if (!more) visibleMine = 10;
        });
      }
    } catch (e) {
      if (mounted && current == generation) setState(() => error = _message(e));
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  String _message(Object e) => e is PlatformException
      ? (e.message ?? e.code)
      : e.toString().replaceFirst('Bad state: ', '');
  Future<bool> _review(String title, Map<String, Object?> details) async {
    if (!mounted) return false;
    final approved = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        _NftReview(title: title, details: details))) ==
            true &&
        mounted;
    if (!approved) approvalCancelled = true;
    return approved;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      approvalCancelled = false;
    });
    try {
      if (!await NativeSecurity().hasNativeWalletFor(widget.address)) {
        throw StateError(
            'A signing wallet is required. Watch wallets cannot list, buy or cancel.');
      }
      await action();
      if (mounted && !approvalCancelled) {
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Marketplace updated'),
                    content: const Text(
                        'The action is saved. Browse and My listings refresh now. If the indexer is still confirming it, use Reload shortly.'),
                    actions: [
                      FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Done'))
                    ]));
      }
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        final message = error;
        await _load();
        if (mounted && message != null) setState(() => error = message);
        if (mounted) _retryPublication();
      }
    }
  }

  Future<void> _list(Map<String, Object?> nft) async {
    if (busy) return;
    final controller = TextEditingController(
        text: nft['suggestedPriceSompi'] == null
            ? ''
            : nftKas(nft['suggestedPriceSompi'])
                .replaceAll(' KAS', '')
                .replaceAll(',', ''));
    final amount = await showDialog<int>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text('List ${nft['ticker']} #${nft['tokenId']}'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'Seller-signed PSKT. No escrow. You receive 97.9% of the price; the 2.1% marketplace fee goes to hub21.kas. Listing and cancellation cost network fees. Cancel before changing the price.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          TextInputFormatter.withFunction((old, next) =>
                              RegExp(r'^\d*(?:\.\d{0,8})?$').hasMatch(next.text)
                                  ? next
                                  : old)
                        ],
                        decoration: const InputDecoration(
                            labelText: 'Seller price in KAS'),
                        onChanged: (_) => update(() {})),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: nftPrice(controller.text) == null
                            ? null
                            : () => Navigator.pop(
                                context, nftPrice(controller.text)),
                        child: const Text('Review listing'))
                  ],
                )));
    // Do not dispose a controller before the dialog's reverse animation ends.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (amount == null || !mounted) return;
    await _run(() => service.create(widget.address, nft, amount, _review));
    if (mounted) {
      setState(() => tab = 2);
      final message = error;
      await _load();
      if (mounted && message != null) setState(() => error = message);
    }
  }

  Widget _image(Map<String, Object?> item) => SizedBox(
      width: 92,
      height: 92,
      child: item['imageUrl'] == null
          ? const Icon(Icons.image_outlined)
          : Krc721Image(item['imageUrl']! as String));
  Widget _offer(Map<String, Object?> item, {bool mine = false}) {
    final status = (item['status'] ?? 'pending').toString();
    final active = status == 'active';
    final pending = item['stage'] != null && item['stage'] != 'complete';
    final details =
        item['traits'] is Map ? nftMap(item['traits']) : <String, Object?>{};
    final percentages = item['traitRarity'] is Map
        ? nftMap(item['traitRarity'])
        : <String, Object?>{};
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    _image(item),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('${item['ticker']} #${item['tokenId']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text(item['rarityRank'] == null
                              ? 'Rarity rank unavailable'
                              : 'Rarity rank #${item['rarityRank']}'),
                          Text(nftKas(item['priceSompi'])),
                          if (tab != 0 || !active)
                            Text(status[0].toUpperCase() + status.substring(1))
                        ]))
                  ]),
                  ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Seller & NFT traits'),
                      children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                                'Seller wallet\n${item['seller'] ?? 'Unavailable'}')),
                        for (final trait in details.entries)
                          ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(trait.key),
                              subtitle: Text('${trait.value}'),
                              trailing: percentages[trait.key] == null
                                  ? null
                                  : Text('${percentages[trait.key]}%')),
                        if (details.isEmpty)
                          const Text('No trait data available.')
                      ]),
                  const SizedBox(height: 12),
                  if (mine) ...[
                    if (pending)
                      OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => _run(() => service.resume(item, _review)),
                          icon: const Icon(Icons.restore),
                          label: const Text('Resume listing')),
                    if (!pending && active && item['published'] == false)
                      Text(item['publicationBlocked'] == true
                          ? 'Publication rejected: ${item['publicationError']}'
                          : 'Publishing automatically · waiting for confirmation'),
                    if (!pending && active && item['published'] != false)
                      const Text('Published'),
                    if (!['sold', 'cancelled'].contains(status) &&
                        item['listingTransactionId'] != null)
                      OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => _run(() => service.transact(
                                  widget.address, item, 'cancel', _review)),
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel listing')),
                  ] else if (active)
                    FilledButton(
                        onPressed: busy
                            ? null
                            : () => _run(() => service.transact(
                                widget.address, item, 'buy', _review)),
                        child: const Text('Buy · review PSKT')),
                ])));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('NFT Market'), actions: [
        IconButton(
            tooltip: 'Reload',
            onPressed: busy ? null : () => _load(),
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20, 48 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
            SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Browse')),
                  ButtonSegment(value: 1, label: Text('My NFTs')),
                  ButtonSegment(value: 2, label: Text('My listings'))
                ],
                selected: {
                  tab
                },
                onSelectionChanged: busy
                    ? null
                    : (value) {
                        setState(() => tab = value.single);
                        _load();
                      }),
            const SizedBox(height: 16),
            if (loading || busy) const LinearProgressIndicator(),
            if (error != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(error!))),
            if (tab == 0) ...[
              TextField(
                  controller: search,
                  decoration: const InputDecoration(
                      labelText: 'Search ticker or token ID',
                      prefixIcon: Icon(Icons.search)),
                  onChanged: (_) {
                    debounce?.cancel();
                    debounce =
                        Timer(const Duration(milliseconds: 450), () => _load());
                  },
                  onSubmitted: (_) => _load()),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                  key: ValueKey('collection-$collection'),
                  initialValue: collection ?? '',
                  decoration: const InputDecoration(labelText: 'Collection'),
                  items: [
                    const DropdownMenuItem<String>(
                        value: '', child: Text('All listed collections')),
                    for (final c in collections)
                      DropdownMenuItem(value: c, child: Text(c))
                  ],
                  onChanged: busy
                      ? null
                      : (c) {
                          setState(() {
                            collection = c == '' ? null : c;
                            traits = {};
                            if (collection == null &&
                                sort.startsWith('rank-')) {
                              sort = 'recent';
                            }
                          });
                          _load();
                        }),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                  key: ValueKey('sort-$collection-$sort'),
                  initialValue: sort,
                  decoration: const InputDecoration(labelText: 'Sort offers'),
                  items: [
                    const DropdownMenuItem(
                        value: 'recent', child: Text('Most recent listings')),
                    DropdownMenuItem(
                        value: 'low', child: Text('Price: Low to High')),
                    DropdownMenuItem(
                        value: 'high', child: Text('Price: High to Low')),
                    if (collection != null) ...[
                      const DropdownMenuItem(
                          value: 'rank-low', child: Text('Rank: Low to High')),
                      const DropdownMenuItem(
                          value: 'rank-high', child: Text('Rank: High to Low')),
                    ]
                  ],
                  onChanged: busy
                      ? null
                      : (v) {
                          setState(() => sort = v ?? 'recent');
                          _load();
                        }),
              if (collection != null && options.isNotEmpty)
                Card(
                    child: ExpansionTile(
                        key: ValueKey('traits-$collection'),
                        title: Text(traits.isEmpty
                            ? 'Trait filters'
                            : 'Trait filters (${traits.length} selected)'),
                        childrenPadding: const EdgeInsets.all(12),
                        children: [
                      for (final entry in options.entries)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                    '$collection-${entry.key}-${traits[entry.key]}'),
                                initialValue: traits[entry.key] ?? '',
                                decoration:
                                    InputDecoration(labelText: entry.key),
                                items: [
                                  const DropdownMenuItem<String>(
                                      value: '', child: Text('Any')),
                                  for (final value in entry.value)
                                    DropdownMenuItem(
                                        value: value,
                                        child: Text(value,
                                            overflow: TextOverflow.ellipsis))
                                ],
                                onChanged: busy
                                    ? null
                                    : (value) {
                                        setState(() {
                                          if (value == null || value.isEmpty) {
                                            traits.remove(entry.key);
                                          } else {
                                            traits[entry.key] = value;
                                          }
                                        });
                                        _load();
                                      })),
                    ])),
              const SizedBox(height: 12),
              if (offers.isEmpty && !loading)
                const Hub21Readable(child: Text('No offers found.')),
              ...offers
                  .map((o) => _offer(o, mine: o['seller'] == widget.address)),
              if (nextOffset != null)
                OutlinedButton(
                    onPressed: busy || loading ? null : () => _load(more: true),
                    child: const Text('Load more')),
            ],
            if (tab == 1) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('my-collection-$myCollection'),
                initialValue: myCollection ?? '',
                decoration: const InputDecoration(labelText: 'Collection'),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('All my collections')),
                  for (final c in myCollections)
                    DropdownMenuItem(value: c, child: Text(c))
                ],
                onChanged: busy
                    ? null
                    : (c) {
                        setState(() => myCollection = c == '' ? null : c);
                        _load();
                      },
              ),
              const SizedBox(height: 12),
              if (owned.isEmpty && !loading)
                const Hub21Readable(
                    child: Text('No KRC721 NFTs found for this address.')),
              for (final nft in owned.take(visibleOwned))
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: [
                          Row(children: [
                            _image(nft),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('${nft['ticker']} #${nft['tokenId']}'),
                                  Text(nft['rarityRank'] == null
                                      ? 'Rarity rank unavailable'
                                      : 'Rarity rank #${nft['rarityRank']}')
                                ]))
                          ]),
                          const SizedBox(height: 12),
                          OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      if ((nft['status'] as Map?)?['state'] ==
                                          'listed') {
                                        setState(() => tab = 2);
                                        _load();
                                      } else {
                                        _list(nft);
                                      }
                                    },
                              child: Text(
                                  (nft['status'] as Map?)?['state'] == 'listed'
                                      ? 'Already listed'
                                      : 'List NFT'))
                        ]))),
              if (owned.length > visibleOwned || cursor != null)
                OutlinedButton(
                    onPressed: busy || loading
                        ? null
                        : () async {
                            if (visibleOwned >= owned.length) {
                              await _load(more: true);
                            }
                            if (mounted) setState(() => visibleOwned += 10);
                          },
                    child: const Text('Load more')),
            ],
            if (tab == 2) ...[
              if (pendingBroadcast)
                OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () =>
                            _run(() => service.resumeBroadcast(widget.address)),
                    icon: const Icon(Icons.restore),
                    label: const Text('Resume saved transaction')),
              ...mine.take(visibleMine).map((o) => _offer(o, mine: true)),
              if (mine.length > visibleMine || nextOffset != null)
                OutlinedButton(
                    onPressed: busy || loading
                        ? null
                        : () async {
                            if (visibleMine >= mine.length &&
                                nextOffset != null) {
                              await _load(more: true);
                            }
                            if (mounted) setState(() => visibleMine += 10);
                          },
                    child: const Text('Load more')),
            ],
          ])));
}

class _NftReview extends StatelessWidget {
  const _NftReview({required this.title, required this.details});
  final String title;
  final Map<String, Object?> details;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
              children: [
            for (final entry in details.entries)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.key,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            SelectableText(entry.key.endsWith('(sompi)') &&
                                    entry.value != null
                                ? nftKas(entry.value)
                                : entry.value is Map || entry.value is List
                                    ? const JsonEncoder.withIndent('  ')
                                        .convert(entry.value)
                                    : '${entry.value}')
                          ]))),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('Confirm · authorize')),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
          ])));
}
