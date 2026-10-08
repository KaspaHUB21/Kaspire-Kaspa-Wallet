import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/nexus_service.dart';
import '../services/krc721_reads.dart';
import '../widgets/krc721_image.dart';
import 'nft_market_screen.dart';

const nexusIntro =
    'Never miss the perfect NFT deal. Submit private offers. Negotiate directly with collectors. Receive instant alerts. Settle securely on Kaspire.';

class _NexusOfferDialog extends StatefulWidget {
  const _NexusOfferDialog({required this.counter});
  final bool counter;
  @override
  State<_NexusOfferDialog> createState() => _NexusOfferDialogState();
}

class _NexusOfferDialogState extends State<_NexusOfferDialog> {
  final amount = TextEditingController();
  int days = 30;
  bool acknowledged = false;
  bool get valid =>
      acknowledged &&
      RegExp(r'^\d{1,8}(?:\.\d{1,8})?$').hasMatch(amount.text.trim()) &&
      (double.tryParse(amount.text.trim()) ?? 0) > 0 &&
      (double.tryParse(amount.text.trim()) ?? 0) <= 90000000;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.counter ? 'Counter offer' : 'Make Private Offer'),
          content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                const Text(
                    'Your offer is private and non-binding. No funds are locked.'),
                const SizedBox(height: 16),
                TextField(
                    controller: amount,
                    onChanged: (_) => setState(() => {}),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Amount in KAS:')),
                if (!widget.counter) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                      initialValue: days,
                      decoration: const InputDecoration(labelText: 'Duration:'),
                      items: [7, 14, 21, 30, 60]
                          .map((v) => DropdownMenuItem(
                              value: v, child: Text('$v days')))
                          .toList(),
                      onChanged: (v) => setState(() => days = v ?? 30))
                ],
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: acknowledged,
                    onChanged: (v) => setState(() => acknowledged = v ?? false),
                    title: const Text(
                        'This is a non-binding offer. No funds are locked.'))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(context, {
                          'amountKas': amount.text.trim(),
                          'durationDays': days,
                          'acknowledgedNonBinding': true
                        })
                    : null,
                child: const Text('Submit'))
          ]);
}

class NexusScreen extends StatefulWidget {
  const NexusScreen(
      {super.key,
      required this.address,
      this.initialView = 'home',
      this.collectionId,
      this.tokenId,
      this.service});
  final String address, initialView;
  final String? collectionId, tokenId;
  final NexusService? service;
  @override
  State<NexusScreen> createState() => _NexusScreenState();
}

class _NexusScreenState extends State<NexusScreen> {
  late final service = widget.service ?? NexusService(widget.address);
  final search = TextEditingController();
  String view = 'home',
      ticker = '',
      id = '',
      sort = 'tokenId',
      wallet = '',
      offerTab = 'received';
  Map<String, Object?> data = {};
  List<Map<String, Object?>> rows = [], catalog = [];
  Map<String, List<String>> traits = {};
  int? next;
  bool loading = false;
  int epoch = 0;
  String loadedView = '';
  String? error;
  @override
  void initState() {
    super.initState();
    view = widget.initialView;
    ticker = widget.collectionId ?? '';
    id = widget.tokenId ?? '';
    if (view != 'home') _load();
  }

  @override
  void dispose() {
    service.close();
    search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final stamp = ++epoch;
    if (view != loadedView) {
      rows = [];
      data = {};
      catalog = [];
      next = null;
      loadedView = view;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (['home', 'dashboard', 'notifications'].contains(view) &&
          !service.connected) {
        if (!await service.connect(context)) {
          if (mounted) setState(() => view = 'home');
          return;
        }
      }
      Object? result;
      if (view == 'collection') {
        result = await service
            .request('collection/${Uri.encodeComponent(ticker)}', query: {
          'offset': '${more ? next ?? 0 : 0}',
          'sort': sort,
          'traits': jsonEncode(traits),
          if (wallet.isNotEmpty) 'wallet': wallet
        });
      } else if (view == 'nft') {
        result = await service.request(
            'nft/${Uri.encodeComponent(ticker)}/${Uri.encodeComponent(id)}');
      } else if (view == 'active') {
        result = await service.request('offers/active',
            query: {'offset': '${more ? next ?? 0 : 0}'});
      } else if (view == 'dashboard') {
        result = await service.request('dashboard/$offerTab', private: true);
      } else if (view == 'notifications') {
        result =
            await service.request('dashboard/notifications', private: true);
      }
      if (!mounted || stamp != epoch) return;
      data = nexusMap(result);
      final page = nexusRows(view == 'collection'
          ? data['tokens']
          : view == 'active'
              ? data['offers']
              : result);
      rows = more ? [...rows, ...page] : page;
      next = data['nextOffset'] as int?;
      catalog = nexusRows(data['catalog']);
      if (view == 'notifications') {
        await service.request('notifications/read', private: true, body: {});
      }
    } catch (e) {
      if (mounted && stamp == epoch) {
        error = e.toString().replaceFirst('Bad state: ', '');
      }
    } finally {
      if (mounted && stamp == epoch) setState(() => loading = false);
    }
  }

  Future<void> _search() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = nexusMap(
          await service.request('search', query: {'q': search.text.trim()}));
      if (!mounted) return;
      view = result['kind'].toString();
      wallet = '';
      traits = {};
      sort = 'tokenId';
      if (view == 'wallet') {
        wallet = result['walletAddress'].toString();
        rows = nexusRows(result['collections']);
        data = result;
        setState(() => loading = false);
      } else {
        ticker = result['collectionId'].toString();
        id = result['tokenId']?.toString() ?? '';
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString().replaceFirst('Bad state: ', '');
          loading = false;
        });
      }
    }
  }

  void _openNft(Map<String, Object?> row) {
    ticker = (row['collectionId'] ?? row['ticker']).toString();
    id = row['tokenId'].toString();
    view = 'nft';
    _load();
  }

  Widget _image(Map<String, Object?> item, {double height = 160}) => SizedBox(
      height: height,
      child: Krc721Image((item['imageUrl'] ??
              Krc721Reads.image((item['ticker'] ?? ticker).toString(),
                  item['tokenId'].toString()))
          .toString()));
  Widget _token(Map<String, Object?> row) => Card(
      child: InkWell(
          onTap: () => _openNft(row),
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _image(row),
                    Text(
                        '${row['ticker'] ?? row['collectionId']} #${row['tokenId']}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(_rank(row['rarityRank'])),
                    if (view == 'active') ...[
                      Text('${row['amountKas']} KAS'),
                      Text(row['statusLabel']?.toString() ??
                          row['status'].toString())
                    ]
                  ]))));
  String _rank(Object? rank) => rank == null
      ? 'Rarity rank unavailable'
      : rank == -1
          ? 'Legendary'
          : 'Rarity rank #$rank';
  Future<void> _offer({Map<String, Object?>? existing}) async {
    if (!service.connected && !await service.connect(context)) return;
    if (!mounted) return;
    final body = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (_) => _NexusOfferDialog(counter: existing != null));
    if (body == null) return;
    setState(() => loading = true);
    try {
      await service.request(
          existing == null ? 'offers' : 'offers/${existing['id']}/counter',
          private: true,
          body: {
            ...body,
            if (existing == null) 'collectionId': ticker,
            if (existing == null) 'tokenId': id
          });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text(existing == null ? 'Offer created successfully' : 'Counter offer created successfully'),
                  content: const Text(
                      'Your offer is non-binding. No funds were locked or spent.'),
                  actions: [
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Done'))
                  ]));
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _action(Map<String, Object?> offer, String action) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(action == 'agree-to-relist'
                    ? 'Agree to relist?'
                    : action == 'accept-counter'
                        ? 'Accept counter offer?'
                        : 'Confirm offer action'),
                content: const Text(
                    'This changes only your non-binding offer. No funds are locked or spent.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Confirm'))
                ]));
    if (yes != true) return;
    setState(() => loading = true);
    try {
      await service
          .request('offers/${offer['id']}/$action', private: true, body: {});
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _settle(Map<String, Object?> offer, {required bool seller}) {
    final nft = nexusMap(offer['nftCache']);
    Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => NftMarketScreen(
                address: widget.address,
                initialTab: seller ? 1 : 0,
                initialNft: seller
                    ? {
                        ...nft,
                        'ticker': nft['collectionId'].toString().toUpperCase(),
                        'suggestedPriceSompi': offer['currentAmountSompi']
                      }
                    : null)));
  }

  Widget _offerCard(Map<String, Object?> row) {
    final nft = nexusMap(row['nftCache']),
        state = row['status'].toString(),
        seller = offerTab == 'received';
    final open = state == 'OPEN' &&
        DateTime.tryParse(row['expiresAt'].toString())
                ?.isAfter(DateTime.now()) ==
            true;
    final counter = state == 'COUNTERED' &&
        DateTime.tryParse(row['expiresAt'].toString())
                ?.isAfter(DateTime.now()) ==
            true;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      '${nft['collectionId'].toString().toUpperCase()} #${nft['tokenId']}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(nftKas(row['currentAmountSompi'])),
                  Text(state.replaceAll('_', ' ')),
                  Text('Expires: ${row['expiresAt']}'),
                  ExpansionTile(
                      title: const Text('Offer history'),
                      children: nexusRows(row['revisions'])
                          .map((r) => ListTile(
                              title: Text(
                                  r['type'].toString().replaceAll('_', ' ')),
                              subtitle: Text('${r['createdAt']}'),
                              trailing: r['amountSompi'] == null
                                  ? null
                                  : Text(nftKas(r['amountSompi']))))
                          .toList()),
                  if (seller && open) ...[
                    OutlinedButton(
                        onPressed: loading ? null : () => _offer(existing: row),
                        child: const Text('Counter offer')),
                    OutlinedButton(
                        onPressed:
                            loading ? null : () => _action(row, 'decline'),
                        child: const Text('Decline')),
                    FilledButton(
                        onPressed: loading
                            ? null
                            : () => _action(row, 'agree-to-relist'),
                        child: const Text('Agree to relist'))
                  ],
                  if (!seller && counter) ...[
                    FilledButton(
                        onPressed: loading
                            ? null
                            : () => _action(row, 'accept-counter'),
                        child: const Text('Accept counter offer')),
                    OutlinedButton(
                        onPressed:
                            loading ? null : () => _action(row, 'cancel'),
                        child: const Text('Decline counter offer'))
                  ],
                  if (!seller && open)
                    OutlinedButton(
                        onPressed:
                            loading ? null : () => _action(row, 'cancel'),
                        child: const Text('Cancel offer')),
                  if (seller &&
                      ['AGREED_WAITING_RELIST', 'RELIST_DETECTED']
                          .contains(state))
                    FilledButton(
                        onPressed: () => _settle(row, seller: true),
                        child: const Text('List on Kaspire at agreed price')),
                  if (!seller && state == 'RELIST_DETECTED')
                    FilledButton(
                        onPressed: () => _settle(row, seller: false),
                        child: const Text('Buy on Kaspire · review PSKT')),
                  TextButton(
                      onPressed: () => _openNft(nft),
                      child: const Text('View NFT'))
                ])));
  }

  List<Widget> _details() => [
        _image(data, height: 260),
        Text('${ticker.toUpperCase()} #$id',
            style: Theme.of(context).textTheme.headlineSmall),
        Text(_rank(data['rarityRank'])),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          'Current listing status: ${data['listingStatus'] ?? 'UNKNOWN'}'),
                      if (data['listingPriceSompi'] != null)
                        Text(
                            'Kaspire listing price: ${nftKas(data['listingPriceSompi'])}'),
                      if (data['listingPriceUnavailable'] == true)
                        const Text(
                            'Kaspire listing price is temporarily unavailable.'),
                      if (data['kaspireListing'] != null)
                        FilledButton(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                    builder: (_) => NftMarketScreen(
                                        address: widget.address))),
                            child: const Text('Open Kaspire listing'))
                    ]))),
        Card(
            child: ExpansionTile(
                title: const Text('Owner & NFT traits'),
                children: [
              SelectableText(
                  'Owner wallet\n${data['currentOwnerWallet'] ?? 'Unknown'}'),
              for (final t in nexusRows(data['attributes']))
                ListTile(
                    title: Text('${t['trait_type']}'),
                    subtitle: Text('${t['value']}'))
            ])),
        const Text('Best offers'),
        for (final offer in nexusRows(data['bestOffers']))
          Card(
              child: ListTile(
                  title: Text(nftKas(offer['currentAmountSompi'])),
                  subtitle: Text(
                      '${offer['status']} · Expires ${offer['expiresAt']}'))),
        if (nexusRows(data['bestOffers']).isEmpty)
          const Text('No active offers yet.'),
        if (data['currentOwnerWallet'] != widget.address)
          FilledButton(
              onPressed: loading ? null : () => _offer(),
              child: const Text('Make private offer')),
        OutlinedButton(
            onPressed: () => setState(() {
                  view = 'dashboard';
                  offerTab = data['currentOwnerWallet'] == widget.address
                      ? 'received'
                      : 'sent';
                  _load();
                }),
            child: const Text('My offers')),
      ];
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Nexus Offers'), actions: [
        IconButton(
            tooltip: 'My offers',
            onPressed: () {
              view = 'dashboard';
              _load();
            },
            icon: const Icon(Icons.forum_outlined)),
        IconButton(
            tooltip: 'Notifications',
            onPressed: () {
              view = 'notifications';
              _load();
            },
            icon: const Icon(Icons.notifications_outlined)),
        IconButton(
            tooltip: 'Reload',
            onPressed: loading ? null : () => _load(),
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20, 48 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
            if (view != 'home')
              TextButton.icon(
                  onPressed: () {
                    ++epoch;
                    setState(() {
                      view = 'home';
                      rows = [];
                      data = {};
                      error = null;
                      loading = false;
                    });
                  },
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Nexus home')),
            if (view == 'home') ...[
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(nexusIntro,
                          style: Theme.of(context).textTheme.titleMedium))),
              TextField(
                  controller: search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                      labelText: 'Ticker, ticker + token ID, or wallet')),
              FilledButton.icon(
                  onPressed: loading ? null : _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Search')),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: () {
                    view = 'active';
                    _load();
                  },
                  child: const Text('Browse active offers')),
              OutlinedButton(
                  onPressed: () {
                    view = 'dashboard';
                    _load();
                  },
                  child: const Text('My offers'))
            ],
            if (error != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)))),
            if (view == 'collection') ...[
              Text(ticker.toUpperCase(),
                  style: Theme.of(context).textTheme.headlineSmall),
              if (wallet.isNotEmpty) SelectableText(wallet),
              DropdownButtonFormField<String>(
                  initialValue: sort,
                  items: const [
                    DropdownMenuItem(value: 'tokenId', child: Text('Token ID')),
                    DropdownMenuItem(
                        value: 'rarityRank', child: Text('Rarity Rank'))
                  ],
                  onChanged: (value) {
                    sort = value ?? 'tokenId';
                    _load();
                  }),
              if (catalog.isNotEmpty)
                Card(
                    child: ExpansionTile(
                        title: const Text('Trait filters'),
                        children: [
                      for (final group in catalog)
                        ExpansionTile(
                            title: Text(group['traitType'].toString()),
                            children: [
                              for (final item in nexusRows(group['values']))
                                CheckboxListTile(
                                    title: Text('${item['value']}'),
                                    subtitle: Text(
                                        '${item['count']} NFTs${item['rarity'] == null ? '' : ' · ${item['rarity']}%'}'),
                                    value: traits[group['traitType']]
                                            ?.contains(item['value']) ??
                                        false,
                                    onChanged: loading
                                        ? null
                                        : (value) {
                                            final key = group['traitType']
                                                    .toString(),
                                                v = item['value'].toString(),
                                                values = traits[key] ?? [];
                                            if (value == true) {
                                              values.add(v);
                                            } else {
                                              values.remove(v);
                                            }
                                            if (values.isEmpty) {
                                              traits.remove(key);
                                            } else {
                                              traits[key] = values;
                                            }
                                            _load();
                                          })
                            ])
                    ]))
            ],
            if (view == 'wallet') ...[
              SelectableText(wallet),
              for (final c in rows)
                Card(
                    child: ListTile(
                        title: Text('${c['ticker']}'),
                        subtitle: Text('${c['count']} NFTs'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          ticker = c['collectionId'].toString();
                          view = 'collection';
                          _load();
                        }))
            ],
            if (view == 'nft') ..._details(),
            if (view == 'dashboard') ...[
              SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'received', label: Text('Received offers')),
                    ButtonSegment(value: 'sent', label: Text('Sent offers'))
                  ],
                  selected: {
                    offerTab
                  },
                  onSelectionChanged: (v) {
                    offerTab = v.first;
                    _load();
                  }),
              ...rows.map(_offerCard)
            ],
            if (['collection', 'active'].contains(view)) ...rows.map(_token),
            if (view == 'notifications')
              ...rows.map((n) {
                final payload = nexusMap(n['payloadJson']);
                return Card(
                    child: ListTile(
                        title: Text(payload['title']?.toString() ??
                            n['type'].toString()),
                        subtitle: Text(
                            '${payload['message'] ?? ''}\n${n['createdAt']}'),
                        onTap: payload['collectionId'] != null &&
                                payload['tokenId'] != null
                            ? () => _openNft(payload)
                            : null));
              }),
            if (loading)
              const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator())),
            if (!loading &&
                rows.isEmpty &&
                ['active', 'collection', 'wallet', 'dashboard', 'notifications']
                    .contains(view))
              const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No results found.')),
            if (next != null && ['active', 'collection'].contains(view))
              OutlinedButton(
                  onPressed: loading ? null : () => _load(more: true),
                  child: const Text('Load more')),
          ])));
}
