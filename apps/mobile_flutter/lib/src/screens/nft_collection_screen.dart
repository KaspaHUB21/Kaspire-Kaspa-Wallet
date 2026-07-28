import 'package:flutter/material.dart';

import '../models/wallet_snapshot.dart';
import '../services/kaspa_api.dart';
import '../theme.dart';

class NftCollectionScreen extends StatefulWidget {
  const NftCollectionScreen({
    super.key,
    required this.address,
    required this.ticker,
    required this.onSend,
  });

  final String address;
  final String ticker;
  final ValueChanged<WalletNft> onSend;

  @override
  State<NftCollectionScreen> createState() => _NftCollectionScreenState();
}

class _NftCollectionScreenState extends State<NftCollectionScreen> {
  final _api = KaspaApi();
  NftCollectionPage? _page;
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final next = await _api.loadNftCollection(
        widget.address,
        widget.ticker,
        offset: more ? (_page?.nextOffset ?? 0) : 0,
      );
      if (!mounted) return;
      setState(() {
        _page = more && _page != null
            ? NftCollectionPage(
                ticker: next.ticker,
                total: next.total,
                nfts: [
                  ..._page!.nfts,
                  ...next.nfts.where(
                    (nft) => !_page!.nfts.any(
                      (current) => current.tokenId == nft.tokenId,
                    ),
                  ),
                ],
                nextOffset: next.nextOffset,
              )
            : next;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _showNft(WalletNft nft) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: nft.imageUrl == null
                      ? const _NoImage()
                      : InteractiveViewer(
                          child: Image.network(
                            nft.imageUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const _NoImage(),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${nft.ticker} #${nft.tokenId}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      nft.rarityRank == null
                          ? 'Rarity rank unavailable'
                          : 'Rarity rank #${nft.rarityRank}',
                      style: TextStyle(
                        color: nft.rarityRank == null
                            ? KasVaultTheme.muted
                            : KasVaultTheme.mint,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('CLOSE'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.pop(this.context);
                              widget.onSend(nft);
                            },
                            icon: const Icon(Icons.send_rounded),
                            label: const Text('SEND NFT'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.ticker} NFTs')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && page == null
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            '${page?.total ?? 0} NFTs held',
                            style: const TextStyle(
                              color: KasVaultTheme.muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      if (page == null || page.nfts.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Text('No NFTs returned.')),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          sliver: SliverGrid.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: .78,
                            ),
                            itemCount: page.nfts.length,
                            itemBuilder: (context, index) {
                              final nft = page.nfts[index];
                              return InkWell(
                                onTap: () => _showNft(nft),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: KasVaultTheme.panel,
                                    borderRadius: BorderRadius.circular(16),
                                    border:
                                        Border.all(color: KasVaultTheme.line),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: nft.imageUrl == null
                                            ? const _NoImage()
                                            : Image.network(
                                                nft.imageUrl!,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const _NoImage(),
                                              ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(10),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '#${nft.tokenId}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: KasVaultTheme.mint
                                                    .withValues(alpha: .13),
                                                borderRadius:
                                                    BorderRadius.circular(9),
                                              ),
                                              child: Text(
                                                nft.rarityRank == null
                                                    ? 'RANK —'
                                                    : 'RANK #${nft.rarityRank}',
                                                style: TextStyle(
                                                  color: KasVaultTheme.mint,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      if (page?.nextOffset != null)
                        SliverPadding(
                          padding: const EdgeInsets.all(20),
                          sliver: SliverToBoxAdapter(
                            child: FilledButton(
                              onPressed:
                                  _loadingMore ? null : () => _load(more: true),
                              child: Text(
                                _loadingMore ? 'LOADING…' : 'LOAD MORE',
                              ),
                            ),
                          ),
                        ),
                      if (_error != null && page != null)
                        SliverPadding(
                          padding: const EdgeInsets.all(18),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Color(0xFFFF8A65)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _NoImage extends StatelessWidget {
  const _NoImage();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: KasVaultTheme.panel,
        child: const Center(
          child: Icon(Icons.image_not_supported_outlined,
              color: KasVaultTheme.muted, size: 38),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('RETRY')),
            ],
          ),
        ),
      );
}
