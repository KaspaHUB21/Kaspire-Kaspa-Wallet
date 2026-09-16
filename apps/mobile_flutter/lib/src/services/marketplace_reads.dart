import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class MarketplaceReadUnavailable implements Exception {
  const MarketplaceReadUnavailable();
  @override
  String toString() =>
      'Marketplace verification temporarily unavailable. Please retry.';
}

/// Shared across marketplace screens: at most two requests in flight and
/// eight starts per second, leaving headroom for the wallet's other requests.
class MarketplaceReadScheduler {
  MarketplaceReadScheduler({this.interval = const Duration(milliseconds: 125)});
  final Duration interval;
  final _lanes = [Future<void>.value(), Future<void>.value()];
  Future<void> _startGate = Future<void>.value();
  int _next = 0;

  Future<T> run<T>(Future<T> Function() action) {
    final lane = _next++ % _lanes.length;
    final job = _lanes[lane].then((_) async {
      final start = _startGate.then((_) => Future<void>.delayed(interval));
      _startGate = start;
      await start;
      return action();
    });
    _lanes[lane] =
        job.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return job;
  }
}

class MarketplaceReads {
  MarketplaceReads(this.client,
      {MarketplaceReadScheduler? scheduler,
      this.retryDelay = const Duration(milliseconds: 700)})
      : scheduler = scheduler ?? sharedScheduler;
  static final sharedScheduler = MarketplaceReadScheduler();
  final http.Client client;
  final MarketplaceReadScheduler scheduler;
  final Duration retryDelay;
  final Map<String, Future<Object?>> _pending = {};
  bool _closed = false;
  void close() {
    _closed = true;
  }

  Future<Object?> get(String url) {
    if (_closed) return Future.error(const MarketplaceReadUnavailable());
    final existing = _pending[url];
    if (existing != null) return existing;
    final result = _read(url);
    _pending[url] = result;
    // Only coalesce in-flight reads. Never cache a spendable UTXO or acceptance
    // result across refreshes, reviews or signing operations.
    return result.then((value) {
      _pending.remove(url);
      return value;
    }, onError: (Object error, StackTrace stack) {
      _pending.remove(url);
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<Object?> _read(String url) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      var delay = retryDelay * (1 << attempt);
      try {
        final response = await scheduler.run(() {
          if (_closed) throw const MarketplaceReadUnavailable();
          return client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 12));
        });
        if ([429, 502, 503, 504].contains(response.statusCode)) {
          final seconds = int.tryParse(response.headers['retry-after'] ?? '');
          if (seconds != null && seconds >= 0) {
            delay = Duration(seconds: seconds.clamp(0, 5));
          }
          if (attempt == 3) throw const MarketplaceReadUnavailable();
        } else {
          if (response.statusCode != 200 ||
              response.bodyBytes.length > 4 * 1024 * 1024) {
            throw StateError(
                'Marketplace data unavailable (${response.statusCode}).');
          }
          return jsonDecode(response.body);
        }
      } on TimeoutException {
        if (attempt == 3) throw const MarketplaceReadUnavailable();
      } on http.ClientException {
        if (attempt == 3) throw const MarketplaceReadUnavailable();
      }
      if (_closed) throw const MarketplaceReadUnavailable();
      await Future<void>.delayed(delay);
    }
    throw const MarketplaceReadUnavailable();
  }
}
