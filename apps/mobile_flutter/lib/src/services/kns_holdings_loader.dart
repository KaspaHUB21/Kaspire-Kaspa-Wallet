import 'dart:async';

class KnsHoldingsResult {
  const KnsHoldingsResult(this.records, {this.warning});
  final List<Map<String, Object?>> records;
  final String? warning;
}

/// Reads bounded pages without discarding verified earlier responses if a later
/// request fails. Page length alone is not evidence of completion: servers may
/// cap pageSize below the requested size.
Future<KnsHoldingsResult> loadKnsHoldingsPages({
  required Future<Map<String, Object?>> Function(int page) fetchPage,
  void Function(List<Map<String, Object?>>)? onProgress,
  Duration pageTimeout = const Duration(seconds: 8),
  Duration totalTimeout = const Duration(seconds: 45),
  int maxPages = 100,
}) async {
  final clock = Stopwatch()..start();
  final records = <String, Map<String, Object?>>{};
  var received = 0;
  int integer(Object? value) => int.tryParse('$value') ?? 0;
  Map<String, Object?> map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
  KnsHoldingsResult finish([String? reason]) => KnsHoldingsResult(
        records.values.toList(),
        warning: reason == null
            ? null
            : 'KNS loading incomplete: $reason '
                'Already loaded names are kept. Pull to refresh to retry.',
      );

  for (var page = 1; page <= maxPages; page++) {
    final remaining = totalTimeout - clock.elapsed;
    if (remaining <= Duration.zero) return finish('the indexer took too long.');
    try {
      final raw = await fetchPage(page)
          .timeout(remaining < pageTimeout ? remaining : pageTimeout);
      final data = raw['data'] is Map ? map(raw['data']) : raw;
      final assets = data['assets'];
      if (assets is! List) {
        return finish('the indexer returned an invalid page.');
      }
      final metadata = map(data['pagination'] ?? raw['pagination']);
      final totalPages =
          integer(metadata['totalPages'] ?? metadata['total_pages']);
      final total = integer(metadata['totalItems'] ??
          metadata['total_items'] ??
          metadata['total'] ??
          metadata['totalCount']);
      final explicitMore = metadata['hasMore'] ??
          metadata['hasNextPage'] ??
          metadata['has_more'];
      final next = metadata['nextPage'] ?? metadata['next_page'];
      final before = records.length;
      for (final item in assets.whereType<Map>()) {
        final record = Map<String, Object?>.from(item);
        final assetId =
            (record['assetId'] ?? record['asset_id'])?.toString().trim();
        final key = (assetId != null && assetId.isNotEmpty
                ? assetId
                : (record['asset'] ?? record['domain'] ?? record['name']))
            ?.toString()
            .trim()
            .toLowerCase();
        if (key != null && key.isNotEmpty) records[key] = record;
      }
      received += assets.length;
      onProgress?.call(records.values.toList());
      final more = totalPages > 0
          ? page < totalPages
          : explicitMore is bool
              ? explicitMore
              : integer(next) > page
                  ? true
                  : total > 0
                      ? received < total
                      : assets.isNotEmpty;
      if (!more) return finish();
      if (assets.isEmpty) {
        return finish('the indexer omitted a requested page.');
      }
      if (records.length == before) {
        return finish('the indexer repeated a page.');
      }
    } catch (_) {
      return finish('a page could not be retrieved.');
    }
  }
  return finish('the safety limit for pages was reached.');
}
