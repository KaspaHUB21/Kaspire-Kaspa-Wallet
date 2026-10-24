import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/wallet_snapshot.dart';
import 'activity_store.dart';

typedef ActivitySourceLoader = Future<List<WalletTransaction>> Function(
  void Function(List<WalletTransaction>) publish,
  void Function(String) warn,
);

class ActivityFeedState {
  const ActivityFeedState({
    this.items = const [],
    this.loading = const {},
    this.warnings = const {},
    this.hasMore = false,
  });
  final List<WalletTransaction> items;
  final Set<String> loading;
  final Map<String, String> warnings;
  final bool hasMore;
}

/// Read-only history sources publish independently. A failed source never
/// replaces its previous successful results with a fabricated empty history.
class ActivityFeed extends ValueNotifier<ActivityFeedState> {
  ActivityFeed({this.timeout = const Duration(seconds: 30), this.limit = 50})
      : super(const ActivityFeedState());

  final Duration timeout;
  int limit;
  void showMore() {
    limit += 50;
    _emit();
  }

  final _rows = <String, List<WalletTransaction>>{};
  final _loading = <String>{};
  final _warnings = <String, String>{};
  final _versions = <String, int>{};
  bool _disposed = false;

  void seed(String source, List<WalletTransaction> rows) {
    if (_disposed || rows.isEmpty) return;
    _rows[source] = mergeWalletActivity(_rows[source] ?? const [], rows);
    _emit();
  }

  Future<void> reload(Map<String, ActivitySourceLoader> sources) async {
    if (_disposed) return;
    await Future.wait(
        sources.entries.map((entry) => _load(entry.key, entry.value)));
  }

  Future<void> _load(String source, ActivitySourceLoader loader) async {
    final version = (_versions[source] ?? 0) + 1;
    _versions[source] = version;
    _loading.add(source);
    _warnings.remove(source);
    _emit();
    var accepting = true;
    bool current() => accepting && !_disposed && _versions[source] == version;
    void publish(List<WalletTransaction> rows) {
      if (!current()) return;
      _rows[source] = mergeWalletActivity(_rows[source] ?? const [], rows);
      _emit();
    }

    void warn(String message) {
      if (!current()) return;
      _warnings[source] = message;
      _emit();
    }

    try {
      final rows = await loader(publish, warn).timeout(timeout);
      if (current()) {
        _rows[source] = _warnings.containsKey(source)
            ? mergeWalletActivity(_rows[source] ?? const [], rows)
            : List.of(rows);
        _emit();
      }
    } catch (_) {
      warn(
          '$source is temporarily unavailable. Previously loaded entries are retained.');
    } finally {
      if (current()) {
        _loading.remove(source);
        _emit();
      }
      accepting = false;
    }
  }

  void _emit() {
    if (_disposed) return;
    final merged = mergeWalletActivity(
      _rows['Saved activity'] ?? const [],
      [
        ...?_rows['Other asset history'],
        ..._rows.entries
            .where((entry) =>
                entry.key != 'Saved activity' &&
                entry.key != 'Other asset history')
            .expand((entry) => entry.value),
      ],
    );
    value = ActivityFeedState(
      items: List.unmodifiable(merged.take(limit)),
      hasMore: merged.length > limit,
      loading: Set.unmodifiable(_loading),
      warnings: Map.unmodifiable(_warnings),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
