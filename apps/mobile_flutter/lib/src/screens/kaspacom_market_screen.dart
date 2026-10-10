import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/kaspacom_market_service.dart';
import '../services/nft_market_service.dart';
import '../services/krc721_reads.dart';

/// Internal test entry only. KaspaCom's fees and orders are independent of Agora.
class KaspaComMarketScreen extends StatefulWidget {
  const KaspaComMarketScreen(
      {super.key, required this.address, this.service, this.nftService});
  final String address;
  final KaspaComMarketService? service;
  final NftMarketService? nftService;
  @override
  State<KaspaComMarketScreen> createState() => _KaspaComMarketScreenState();
}

class _KaspaComMarketScreenState extends State<KaspaComMarketScreen> {
  late final market = widget.service ?? KaspaComMarketService(widget.address);
  late final nfts = widget.nftService ?? NftMarketService();
  final search = TextEditingController();
  String kind = 'krc721', tab = 'browse', sort = 'recent';
  String historyRole = 'seller';
  List<String> ownedCollections = [];
  String? ownedCollection;
  Map<String, String> traits = {};
  Map<String, List<String>> traitOptions = {};
  Map<String, Object?> tokenSummary = {};
  final Map<String, Map<String, Object?>> tokenSummaries = {};
  String? metadataTicker, traitWarning;
  List<Map<String, Object?>> rows = [], catalog = [], recovery = [];
  bool loading = false, working = false, more = false, catalogMore = false;
  String? error, nftCursor;
  int offset = 0, catalogOffset = 0, revision = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    market.close();
    nfts.close();
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool append = false}) async {
    if ((kind != 'krc721' || search.text.trim().isEmpty) &&
        sort.startsWith('rank')) {
      sort = 'recent';
    }
    final gen = ++revision,
        k = kind,
        t = tab,
        s = search.text.trim(),
        order = sort,
        selectedTraits = metadataTicker == search.text.trim().toUpperCase()
            ? Map<String, String>.from(traits)
            : <String, String>{};
    setState(() {
      loading = true;
      error = null;
      if (!append) {
        if (metadataTicker != s.toUpperCase()) {
          traits = {};
          traitOptions = {};
        }
        rows = [];
        offset = 0;
        nftCursor = null;
      }
    });
    try {
      final saved = await market.saved();
      if (gen != revision || !mounted) return;
      setState(
          () => recovery = saved.where((r) => r['stage'] != 'done').toList());
      List<Map<String, Object?>> items;
      bool hasMore;
      String? cursor;
      if (t == 'browse') {
        if (k != 'kns' && s.isEmpty) {
          if (!append) catalogOffset = 0;
          final data = await market.catalog(k, catalogOffset);
          items = kcRows(data['items']);
          hasMore = data['nextOffset'] != null ||
              (data['totalCount'] is num &&
                  catalogOffset + items.length < (data['totalCount'] as num));
          if (gen != revision || !mounted) return;
          setState(() {
            catalog = append ? [...catalog, ...items] : items;
            catalogMore = hasMore;
            catalogOffset = (data['nextOffset'] as num?)?.toInt() ??
                catalogOffset + items.length;
            rows = [];
            loading = false;
            more = false;
            recovery = saved.where((r) => r['stage'] != 'done').toList();
          });
          return;
        }
        if (k == 'krc20' && !append) {
          try {
            final summary = await market.tokenSummary(s.toUpperCase());
            if (gen != revision || !mounted) return;
            setState(() => tokenSummary = summary);
            tokenSummaries[s.toUpperCase()] = summary;
          } catch (_) {
            if (gen == revision && mounted) setState(() => tokenSummary = {});
          }
        }
        if (k == 'krc721' && metadataTicker != s.toUpperCase()) {
          try {
            final meta = await market.traitCatalog(s.toUpperCase());
            if (gen != revision || !mounted) return;
            setState(() {
              traitOptions = kcMap(meta['traitOptions'])
                  .map((k, v) => MapEntry(k, (v as List).cast<String>()));
              metadataTicker = s.toUpperCase();
              traitWarning = null;
            });
          } catch (_) {
            if (gen == revision && mounted) {
              setState(() {
                traitOptions = {};
                traitWarning =
                    'Trait filters temporarily unavailable. Reload to retry.';
              });
            }
          }
        }
        final data =
            await market.browse(k, s, order, offset, traits: selectedTraits);
        items = kcRows(data['orders']);
        hasMore = data['nextOffset'] != null;
        if (data['nextOffset'] != null) {
          offset = (data['nextOffset'] as num).toInt() - items.length;
        }
      } else if (t == 'history') {
        final data = await market.history(k, offset, role: historyRole);
        items = kcRows(data['orders']);
        hasMore = data['nextOffset'] != null ||
            offset + items.length < (data['totalCount'] as num? ?? 0);
        if (data['nextOffset'] != null) {
          offset = (data['nextOffset'] as num).toInt() - items.length;
        }
      } else if (k == 'krc721') {
        if (!append) {
          try {
            ownedCollections = await nfts.ownedCollections(widget.address);
            if (ownedCollection != null &&
                !ownedCollections.contains(ownedCollection)) {
              ownedCollection = null;
            }
          } catch (_) {
            /* Owned NFTs remain available when optional filters fail. */
          }
          if (gen != revision || !mounted) return;
        }
        final data = await nfts.owned(widget.address,
            cursor: nftCursor,
            collection:
                ownedCollection ?? (s.isEmpty ? null : s.toUpperCase()));
        items = kcRows(data['items']);
        await market.decorateNftListingStates(items);
        cursor = data['next'] as String?;
        hasMore = cursor != null;
      } else {
        final wallet = await market.api
            .loadWallet(widget.address, includeNativeTransactions: false);
        final all = k == 'krc20'
            ? wallet.krc20Tokens
                .map((a) => <String, Object?>{
                      'ticker': a.symbol,
                      'balance': a.balance,
                      'rawBalance': a.rawBalance,
                      'decimals': a.decimals,
                      'imageUrl': a.imageUrl
                    })
                .toList()
            : wallet.knsDomains
                .map((a) => <String, Object?>{
                      'asset': a.name,
                      'assetId': a.assetId,
                      'status': a.status
                    })
                .toList();
        final filtered = all
            .where((a) =>
                s.isEmpty ||
                (a['ticker'] ?? a['asset'])
                    .toString()
                    .toLowerCase()
                    .contains(s.toLowerCase()))
            .toList();
        items = filtered.skip(offset).take(10).toList();
        if (k == 'kns') await market.decorateKnsListingStates(items);
        hasMore = offset + items.length < filtered.length;
      }
      if (k == 'krc20' && t == 'history') {
        await Future.wait(items
            .map((r) => r['ticker'].toString().toUpperCase())
            .toSet()
            .map((ticker) async {
          try {
            tokenSummaries[ticker] = await market.tokenSummary(ticker);
          } catch (_) {/* Metadata must not hide orders. */}
        }));
      }
      if (gen != revision || !mounted) return;
      setState(() {
        rows = append ? [...rows, ...items] : items;
        offset += items.length;
        nftCursor = cursor;
        more = hasMore;
        recovery = saved.where((r) => r['stage'] != 'done').toList();
        loading = false;
      });
    } catch (e) {
      if (mounted && gen == revision) {
        setState(() {
          loading = false;
          error = message(e);
        });
      }
    }
  }

  String message(Object e) => e.toString().replaceFirst('Bad state: ', '');
  Future<bool> review(String title, Map<String, Object?> details) async {
    if (!mounted) return false;
    return await Navigator.push<bool>(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    _KaspaComReview(title: title, details: details))) ==
        true;
  }

  Future<void> run(Future<dynamic> Function() job, String success) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      market.lastPurchaseReceipt = null;
      market.lastRecoveryMessage = null;
      final result = await job();
      if (!mounted) return;
      final receipt = result is KaspaComPurchaseResult
          ? result.receipt
          : market.lastPurchaseReceipt;
      if (receipt != null) {
        await Navigator.push<void>(
            context,
            MaterialPageRoute(
                builder: (_) => KaspaComPurchaseSuccess(receipt: receipt)));
      } else {
        await showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
                    title: const Text('KaspaCom Marketplace'),
                    content: Text(market.lastRecoveryMessage ?? success),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('Done'))
                    ]));
      }
      await load();
    } on KaspaComCancelled {
      await load();
    } catch (e) {
      final saved = await market.saved();
      if (mounted) {
        setState(() {
          error = message(e);
          recovery = saved.where((r) => r['stage'] != 'done').toList();
        });
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> openOrder(Map<String, Object?> row) async {
    setState(() => error = null);
    try {
      final detail = await market.detail(kind, row['orderId'].toString());
      Map<String, Object?> summary = {};
      if (kind == 'krc20') {
        final ticker = detail['ticker'].toString().toUpperCase();
        try {
          summary = await market.tokenSummary(ticker);
          tokenSummaries[ticker] = summary;
        } catch (_) {
          summary = tokenSummaries[ticker] ?? {};
        }
      }
      if (!mounted) return;
      final seller = detail['sellerWalletAddress']?.toString() ?? '',
          own = seller == widget.address;
      final action = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: Text(label(detail)),
                  content: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        if (kind == 'krc721') image(detail, 180),
                        Text('Price: ${detail['totalPrice']} KAS'),
                        if (kind == 'krc20') ...[
                          Text(
                              'Floor: ${kcPrice(summary['floorPrice'])} KAS / ${detail['ticker']}'),
                          Text(
                              'Price: ${kcPrice(detail['pricePerToken'] ?? _perToken(detail))} KAS / ${detail['ticker']}'),
                          Text(
                              '1 KAS = ${kcPrice(_tokensPerKas(detail))} ${detail['ticker']}'),
                        ],
                        Text('KaspaCom fee: ${detail['currentFee']} KAS'),
                        if (kind == 'krc721')
                          Text('Royalty: ${detail['royaltyFee'] ?? 0} KAS'),
                        const SizedBox(height: 12),
                        const Text('Seller'),
                        SelectableText(seller),
                        const SizedBox(height: 12),
                        Text('Status: ${detail['status']}'),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Back')),
                    if (detail['status'] == 'LISTED_FOR_SALE')
                      FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child:
                              Text(own ? 'Cancel listing' : 'Review purchase'))
                  ]));
      if (action == true) {
        await run(
            () => market.transact(kind, detail, !own, review),
            own
                ? 'Listing cancellation submitted.'
                : 'Purchase submitted successfully.');
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
  }

  Future<void> sell(Map<String, Object?> asset) async {
    final price = TextEditingController(),
        amount = TextEditingController(),
        unitPrice = TextEditingController();
    String? floor;
    try {
      if (kind == 'krc20') {
        try {
          final summary = await market.tokenSummary(asset['ticker'].toString());
          if (summary['floorPrice'] != null) {
            floor = kcPrice(summary['floorPrice']);
            unitPrice.text = floor;
          }
        } catch (_) {
          /* Users can enter a unit price if the floor is unavailable. */
        }
        if (!mounted) return;
      }
      void updateTotal() {
        try {
          price.text = kcListingTotal(amount.text, unitPrice.text);
        } catch (_) {
          price.clear();
        }
      }

      amount.addListener(updateTotal);
      unitPrice.addListener(updateTotal);
      final route = DialogRoute<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: Text('List ${label(asset)}'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (kind == 'krc20') ...[
                      Text('Available: ${asset['balance']} ${asset['ticker']}'),
                      Text(
                          'Floor Price: ${floor ?? 'Unavailable'} KAS / ${asset['ticker']}'),
                      const SizedBox(height: 12),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Token amount')),
                      const SizedBox(height: 12),
                      TextField(
                          controller: unitPrice,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Price per token in KAS')),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                        controller: price,
                        readOnly: kind == 'krc20',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: 'Total price in KAS',
                            helperText:
                                'KaspaCom total is rounded to two decimals')),
                    if (kind == 'krc20')
                      ValueListenableBuilder<TextEditingValue>(
                          valueListenable: price,
                          builder: (_, value, __) {
                            final q = double.tryParse(
                                    amount.text.replaceAll(',', '.')),
                                total = double.tryParse(value.text);
                            return q != null && q > 0 && total != null
                                ? Text(
                                    'Actual price per token: ${kcPrice(total / q)} KAS')
                                : const SizedBox.shrink();
                          }),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Review listing'))
                  ]));
      final accepted = await Navigator.of(context).push(route);
      // Text fields remain mounted during the dialog's reverse transition.
      // Dispose their controllers only after the overlay is actually removed.
      await route.completed;
      if (accepted != true) return;
      final value = kcSompi(price.text.trim().replaceAll(',', '.'));
      if (value < 1000000) {
        throw StateError(
            'KaspaCom listings require a total price of at least 0.01 KAS. Increase the amount or price per token.');
      }
      String raw = '';
      num quantity = 1;
      if (kind == 'krc20') {
        final text = amount.text.trim().replaceAll(',', '.');
        final decimals = (asset['decimals'] as num? ?? 0).toInt();
        if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text) ||
            decimals < 0 ||
            decimals > 18) {
          throw StateError('Enter a valid token amount.');
        }
        final parts = text.split('.');
        if (parts.length > 1 && parts[1].length > decimals) {
          throw StateError('This token supports $decimals decimal places.');
        }
        final units = BigInt.parse(parts.first) *
                BigInt.from(10).pow(decimals) +
            BigInt.parse((parts.length > 1 ? parts[1] : '')
                    .padRight(decimals, '0')
                    .isEmpty
                ? '0'
                : (parts.length > 1 ? parts[1] : '').padRight(decimals, '0'));
        final balance = asset['rawBalance'] != null
            ? BigInt.parse(asset['rawBalance'].toString())
            : BigInt.from(((asset['balance'] as num) *
                    BigInt.from(10).pow(decimals).toDouble())
                .round());
        if (units <= BigInt.zero || units > balance) {
          throw StateError(
              'Insufficient token balance. Available: ${asset['balance']} ${asset['ticker']}.');
        }
        quantity = num.parse(text);
        if (quantity > 9007199254740991) {
          throw StateError(
              'Token quantity exceeds the KaspaCom API precision limit.');
        }
        raw = units.toString();
      }
      await run(() => market.create(kind, asset, value, raw, quantity, review),
          'Listing published on KaspaCom.');
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    } finally {
      price.dispose();
      amount.dispose();
      unitPrice.dispose();
    }
  }

  String label(Map<String, Object?> r) =>
      r['asset']?.toString() ??
      '${r['ticker'] ?? ''}${kind == 'krc721' ? ' #${r['tokenId'] ?? ''}' : ''}';
  Widget image(Map<String, Object?> r, double size) {
    final source = kind == 'krc721'
        ? (r['tokenId'] != null
            ? Krc721Reads.image(r['ticker'].toString(), r['tokenId'].toString())
            : r['imageUrl']?.toString() ??
                Krc721Reads.image(r['ticker'].toString(), '1'))
        : [
            r['imageUrl'],
            r['logoUrl'],
            kcMap(r['metadata'])['logo'],
            tokenSummaries[r['ticker'].toString().toUpperCase()]?['imageUrl'],
            if (r['ticker'] == tokenSummary['ticker']) tokenSummary['imageUrl']
          ]
            .map((v) => v?.toString() ?? '')
            .where((v) => v.isNotEmpty)
            .firstOrNull;
    return SizedBox(
        width: size,
        height: size,
        child: source == null || source.isEmpty
            ? const Icon(Icons.token_outlined)
            : ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(source,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.image_not_supported_outlined))));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('KaspaCom Marketplace'), actions: [
        IconButton(
            onPressed: loading || working ? null : () => load(),
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: Column(children: [
        if (kind == 'krc20' && tab == 'browse' && search.text.trim().isNotEmpty)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                  child: ListTile(
                leading:
                    image({'ticker': search.text.trim().toUpperCase()}, 44),
                title: Text(search.text.trim().toUpperCase()),
                subtitle: Text(
                    'Floor: ${kcPrice(tokenSummaries[search.text.trim().toUpperCase()]?['floorPrice'])} KAS / ${search.text.trim().toUpperCase()}'),
              ))),
        Expanded(
            child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                children: [
              const Card(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'KaspaCom L1 Marketplace\nDecentralized PSKT listings for NFTs, tokens and names. KaspaCom platform fees and NFT royalties are shown before signing.'))),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'krc721', label: Text('KRC-721')),
                    ButtonSegment(value: 'krc20', label: Text('KRC-20')),
                    ButtonSegment(value: 'kns', label: Text('KNS'))
                  ],
                  selected: {
                    kind
                  },
                  onSelectionChanged: working
                      ? null
                      : (v) {
                          setState(() {
                            kind = v.first;
                            sort = 'recent';
                            traits = {};
                            traitOptions = {};
                            metadataTicker = null;
                            tokenSummary = {};
                            traitWarning = null;
                            search.clear();
                            catalog = [];
                          });
                          load();
                        }),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'browse', label: Text('Browse')),
                    ButtonSegment(value: 'assets', label: Text('My assets')),
                    ButtonSegment(value: 'history', label: Text('My orders'))
                  ],
                  selected: {
                    tab
                  },
                  onSelectionChanged: working
                      ? null
                      : (v) {
                          setState(() => tab = v.first);
                          load();
                        }),
              const SizedBox(height: 12),
              if (tab == 'history') ...[
                SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'seller', label: Text('My listings')),
                      ButtonSegment(value: 'buyer', label: Text('Purchases')),
                      ButtonSegment(value: 'sales', label: Text('Sales')),
                    ],
                    selected: {
                      historyRole
                    },
                    onSelectionChanged: working
                        ? null
                        : (v) {
                            setState(() => historyRole = v.first);
                            load();
                          }),
                const SizedBox(height: 12),
              ],
              if (tab == 'assets' && kind == 'krc721')
                DropdownButtonFormField<String>(
                    key: ValueKey(
                        'owned-$ownedCollection-${ownedCollections.join(',')}'),
                    isExpanded: true,
                    initialValue: ownedCollections.contains(ownedCollection)
                        ? ownedCollection
                        : '',
                    decoration: const InputDecoration(labelText: 'Collection'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('All collections')),
                      for (final tick in ownedCollections)
                        DropdownMenuItem(value: tick, child: Text(tick))
                    ],
                    onChanged: working
                        ? null
                        : (v) {
                            setState(() {
                              ownedCollection = v == '' ? null : v;
                              search.clear();
                            });
                            load();
                          }),
              if (!(tab == 'assets' && kind == 'krc721'))
                TextField(
                    controller: search,
                    enabled: !working,
                    decoration: InputDecoration(
                        labelText: kind == 'kns'
                            ? 'Search names'
                            : kind == 'krc721'
                                ? 'NFT collection ticker'
                                : 'Token ticker',
                        suffixIcon: IconButton(
                            onPressed: working ? null : () => load(),
                            icon: const Icon(Icons.search))),
                    onSubmitted: (_) {
                      traits = {};
                      traitOptions = {};
                      metadataTicker = null;
                      load();
                    }),
              if (tab == 'browse') ...[
                const SizedBox(height: 12),
                if (kind != 'krc20')
                  DropdownButtonFormField<String>(
                      key: ValueKey('sort-$kind-$sort'),
                      isExpanded: true,
                      initialValue: sort,
                      decoration:
                          const InputDecoration(labelText: 'Sort all offers'),
                      items: [
                        const DropdownMenuItem(
                            value: 'recent',
                            child: Text('Most recent listings',
                                overflow: TextOverflow.ellipsis)),
                        const DropdownMenuItem(
                            value: 'low',
                            child: Text('Price: Low to High',
                                overflow: TextOverflow.ellipsis)),
                        const DropdownMenuItem(
                            value: 'high',
                            child: Text('Price: High to Low',
                                overflow: TextOverflow.ellipsis)),
                        if (kind == 'krc721' &&
                            search.text.trim().isNotEmpty) ...[
                          const DropdownMenuItem(
                              value: 'rankLow',
                              child: Text('Rank (asc)',
                                  overflow: TextOverflow.ellipsis)),
                          const DropdownMenuItem(
                              value: 'rankHigh',
                              child: Text('Rank (desc)',
                                  overflow: TextOverflow.ellipsis)),
                        ],
                      ],
                      onChanged: working
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => sort = v);
                                load();
                              }
                            }),
                if (kind == 'krc721' && search.text.trim().isNotEmpty)
                  Card(
                      child: ExpansionTile(
                    key: ValueKey(
                        'kaspacom-traits-${search.text.trim().toUpperCase()}'),
                    title: Text(traits.isEmpty
                        ? 'Trait filters'
                        : 'Trait filters (${traits.length} selected)'),
                    childrenPadding: const EdgeInsets.all(12),
                    children: [
                      if (traitWarning != null) Text(traitWarning!),
                      if (traitOptions.isEmpty && traitWarning == null)
                        const Text('No traits available for these listings.'),
                      for (final e in traitOptions.entries)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(
                                  '$metadataTicker-${e.key}-${traits[e.key]}'),
                              isExpanded: true,
                              initialValue: traits[e.key] ?? '',
                              decoration: InputDecoration(labelText: e.key),
                              items: [
                                const DropdownMenuItem(
                                    value: '', child: Text('Any')),
                                for (final v in e.value)
                                  DropdownMenuItem(
                                      value: v,
                                      child: Text(v,
                                          overflow: TextOverflow.ellipsis))
                              ],
                              onChanged: working
                                  ? null
                                  : (v) {
                                      setState(() {
                                        if (v == null || v.isEmpty) {
                                          traits.remove(e.key);
                                        } else {
                                          traits[e.key] = v;
                                        }
                                      });
                                      load();
                                    },
                            )),
                      if (traits.isNotEmpty)
                        TextButton(
                            onPressed: working
                                ? null
                                : () {
                                    setState(() => traits = {});
                                    load();
                                  },
                            child: const Text('Clear trait filters')),
                    ],
                  )),
              ],
              if (working) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                        'Processing your request. Signed transactions are saved before submission.'))
              ],
              if (error != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)))),
              for (final r in recovery) ...[
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Saved ${r['kind']} ${r['action']} · ${r['stage']}'),
                              FilledButton.tonal(
                                  onPressed: working
                                      ? null
                                      : () => run(
                                          () => market.resume(r, review),
                                          'Saved transaction resumed successfully.'),
                                  child: const Text(
                                      'Check / resume saved transaction')),
                              if (r['action'] == 'buy')
                                const Text(
                                    'A saved signature does not mean payment was sent. '
                                    'If this listing was cancelled or sold, checking it will safely release the saved attempt.')
                            ])))
              ],
              if (tab == 'browse' &&
                  search.text.trim().isEmpty &&
                  kind != 'kns') ...[
                for (final c in catalog)
                  Card(
                      child: ListTile(
                          leading: image(c, 44),
                          title: Text(c['ticker'].toString()),
                          subtitle: Text(
                              '${kind == 'krc721' ? 'Floor Price: ' : ''}${kcPrice(c['price'])} KAS · ${c['totalHolders'] ?? '—'} holders'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: working
                              ? null
                              : () {
                                  search.text = c['ticker'].toString();
                                  traits = {};
                                  traitOptions = {};
                                  metadataTicker = null;
                                  tokenSummary = {};
                                  load();
                                })),
                if (catalogMore && !loading)
                  OutlinedButton(
                      onPressed: () => load(append: true),
                      child: const Text('Load more collections / tokens')),
              ] else ...[
                for (final r in rows)
                  if (kind == 'krc20' && tab == 'browse')
                    tokenOrder(r)
                  else
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    if (kind != 'kns') ...[
                                      image(r, 60),
                                      const SizedBox(width: 12)
                                    ],
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text(label(r),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          if (tab == 'assets' &&
                                              kind == 'krc20')
                                            Text('Available: ${r['balance']}'),
                                          if (r['totalPrice'] != null)
                                            Text('${r['totalPrice']} KAS'),
                                          if (r['quantity'] != null)
                                            Text('${r['quantity']} tokens'),
                                          if (kind == 'krc20' &&
                                              tab == 'browse') ...[
                                            Text(
                                                'Floor: ${kcPrice(tokenSummary['floorPrice'])} KAS / ${r['ticker']}'),
                                            Text(
                                                'Price: ${kcPrice(r['pricePerToken'] ?? _perToken(r))} KAS / ${r['ticker']}'),
                                            Text(
                                                '1 KAS = ${kcPrice(_tokensPerKas(r))} ${r['ticker']}'),
                                          ],
                                          if (r['rarityRank'] != null)
                                            Text(
                                                'Rarity rank #${r['rarityRank']}'),
                                          if (tab == 'history')
                                            Text(r['status']?.toString() ?? '')
                                        ]))
                                  ]),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton(
                                          onPressed: working ||
                                                  (tab == 'assets' &&
                                                      (kind == 'krc721' ||
                                                          kind == 'kns') &&
                                                      (r['marketplaceListed'] ==
                                                              true ||
                                                          r['listingPending'] ==
                                                              true))
                                              ? null
                                              : () => tab == 'assets'
                                                  ? sell(r)
                                                  : openOrder(r),
                                          child: Text(tab == 'assets'
                                              ? (kind == 'krc721' ||
                                                          kind == 'kns') &&
                                                      r['marketplaceListed'] ==
                                                          true
                                                  ? 'Already listed'
                                                  : (kind == 'krc721' ||
                                                              kind == 'kns') &&
                                                          r['listingPending'] ==
                                                              true
                                                      ? 'Listing in progress'
                                                      : 'List on KaspaCom'
                                              : 'View order'))),
                                ]))),
                if (more && !loading)
                  OutlinedButton(
                      onPressed: () => load(append: true),
                      child: const Text('Load more')),
                if (rows.isEmpty && !loading)
                  const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No orders or assets found.')),
              ],
              if (loading)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator())),
            ]))
      ])));

  Widget tokenOrder(Map<String, Object?> r) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text('${kcPrice(r['totalPrice'])} KAS',
                      style: const TextStyle(fontWeight: FontWeight.bold))),
              const Icon(Icons.chevron_right),
              const SizedBox(width: 8),
              image(r, 36),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                    Text(kcPrice(r['quantity']),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(label(r))
                  ])),
            ]),
            const SizedBox(height: 8),
            Text(
                'Price: ${kcPrice(r['pricePerToken'] ?? _perToken(r))} KAS / ${r['ticker']}'),
            Text('1 KAS = ${kcPrice(_tokensPerKas(r))} ${r['ticker']}'),
            Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                    onPressed: working ? null : () => openOrder(r),
                    child: const Text('View order'))),
          ])));
}

class KaspaComPurchaseSuccess extends StatelessWidget {
  const KaspaComPurchaseSuccess({super.key, required this.receipt});
  final Map<String, Object?> receipt;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Purchase successful')),
        body: SafeArea(
            child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                children: [
              const Icon(Icons.check_circle_outline, size: 64),
              const SizedBox(height: 16),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final e in receipt.entries) ...[
                              Text(e.key,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              SelectableText(e.value.toString()),
                              const SizedBox(height: 12),
                            ],
                          ]))),
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Return to marketplace')),
            ])),
      );
}

double? _perToken(Map<String, Object?> r) {
  final price = (r['totalPrice'] as num?)?.toDouble(),
      quantity = (r['quantity'] as num?)?.toDouble();
  return price != null && quantity != null && quantity > 0
      ? price / quantity
      : null;
}

double? _tokensPerKas(Map<String, Object?> r) {
  final p = _perToken(r);
  return p != null && p > 0 ? 1 / p : null;
}

class _KaspaComReview extends StatelessWidget {
  const _KaspaComReview({required this.title, required this.details});
  final String title;
  final Map<String, Object?> details;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
              children: [
            for (final e in details.entries)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.key,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            SelectableText(e.key.endsWith('(sompi)')
                                ? '${kcKas(e.value)} KAS'
                                : e.value is List
                                    ? const JsonEncoder.withIndent('  ')
                                        .convert(e.value)
                                    : e.value.toString())
                          ]))),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('Confirm')),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'))
          ])));
}
