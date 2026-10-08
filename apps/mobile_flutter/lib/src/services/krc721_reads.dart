import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Display data only. Never use this client for transaction authorization.
class Krc721Reads {
  Krc721Reads(
    this.client, {
    this.localBase = 'https://kaspire.kaslab.space/krc721-read-v1',
    this.officialBase =
        'https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet',
    this.metadataBase = 'https://api.kaspa.com',
    this.timeout = const Duration(seconds: 5),
    this.officialTimeout = const Duration(seconds: 15),
  });
  final http.Client client;
  final String localBase, officialBase, metadataBase;
  final Duration timeout, officialTimeout;
  static const imageBase = 'https://kaspire.kaslab.space/krc721-read-v1/images';
  static String image(String ticker, String id) =>
      '$imageBase/${Uri.encodeComponent(ticker.toUpperCase())}/${Uri.encodeComponent(id)}';

  bool _unavailable(int code) => code >= 500 || code == 408 || code == 429;
  Map<String, Object?> _map(String body) =>
      (jsonDecode(body) as Map).cast<String, Object?>();
  Future<Map<String, Object?>> walletPage(String address,
      {String? cursor, int limit = 50, String? ticker}) async {
    final path =
        '/address/${Uri.encodeComponent(address)}${ticker == null ? '' : '/${Uri.encodeComponent(ticker)}'}';
    final query = {
      'limit': '$limit',
      'direction': 'forward',
      if (cursor != null) 'offset': cursor
    };
    http.Response? response;
    try {
      response = await client
          .get(Uri.parse('$localBase$path').replace(queryParameters: query))
          .timeout(timeout);
      if (response.statusCode != 200) {
        response = null;
      } else {
        final data = _map(response.body);
        if (data['result'] is! List ||
            (data['message'] != null && data['message'] != 'success')) {
          response = null;
        }
      }
    } catch (_) {
      response = null;
    }
    // A valid healthy empty result is authoritative. An unavailable or broken
    // local response must not prevent the official emergency source loading.
    response ??= await client
        .get(Uri.parse('$officialBase$path').replace(queryParameters: query))
        .timeout(officialTimeout);
    if (response.statusCode != 200) {
      throw StateError('NFT lookup unavailable (${response.statusCode}).');
    }
    final data = _map(response.body);
    if (data['result'] is! List ||
        (data['message'] != null && data['message'] != 'success')) {
      throw const FormatException('Invalid NFT wallet response');
    }
    return data;
  }

  Future<List<Map<String, Object?>>> metadata(
      String ticker, List<String> ids) async {
    if (ids.isEmpty) return [];
    List<Map<String, Object?>> local = [];
    var useFallback = false;
    try {
      final response = await client
          .get(Uri.parse(
                  '$localBase/metadata/${Uri.encodeComponent(ticker.toUpperCase())}')
              .replace(queryParameters: {'ids': ids.join(',')}))
          .timeout(timeout);
      if (_unavailable(response.statusCode) || response.statusCode == 404) {
        useFallback = true;
      } else if (response.statusCode == 200) {
        final data = _map(response.body);
        local = (data['items'] as List)
            .map((v) => (v as Map).cast<String, Object?>())
            .toList();
        useFallback = data['ranksAvailable'] == false;
      } else {
        useFallback = true;
      }
    } catch (_) {
      useFallback = true;
    }
    if (!useFallback) return local;
    try {
      final response = await client
          .post(Uri.parse('$metadataBase/krc721/tokens'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'ticker': ticker.toUpperCase(),
                'tokenIds': ids,
                'limit': ids.length,
                'offset': 0,
                'sortField': 'tokenId',
                'sortDirection': 'asc',
                'traits': <String, Object?>{},
              }))
          .timeout(timeout);
      if (response.statusCode == 200) {
        final remote = (_map(response.body)['items'] as List? ?? [])
            .map((v) => (v as Map).cast<String, Object?>());
        final byId = {
          for (final item in local) item['tokenId'].toString(): item
        };
        for (final item in remote) {
          final id = item['tokenId'].toString();
          if (!ids.contains(id)) continue;
          byId[id] = {
            ...item,
            ...?byId[id],
            'rarityRank': byId[id]?['rarityRank'] ?? item['rarityRank']
          };
        }
        return byId.values.toList();
      }
    } catch (_) {/* Optional display metadata must never hide owned NFTs. */}
    return local;
  }
}

/// Transaction preflight deliberately never uses local display data/fallbacks.
Future<void> requireOfficialNftOwner(
    http.Client client, String sender, String ticker, String tokenId) async {
  final response = await client
      .get(Uri.parse(
          'https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet/nfts/${Uri.encodeComponent(ticker.toLowerCase())}/${Uri.encodeComponent(tokenId)}'))
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    throw StateError(
        'Official KRC721 indexer unavailable. No NFT transaction was sent; try again later.');
  }
  final nft = ((jsonDecode(response.body) as Map)['result'] as Map?);
  if (nft?['owner'] != sender) {
    throw StateError(
        'The official KRC721 indexer does not confirm this wallet as NFT owner. Refresh and retry.');
  }
  if ((nft?['status'] as Map?)?['state'] == 'listed') {
    throw StateError(
        'This NFT is already listed. Cancel its existing listing before sending or relisting.');
  }
}
