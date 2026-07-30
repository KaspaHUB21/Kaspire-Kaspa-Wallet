import 'kaspa_api.dart';
import 'native_security.dart';

class HdDiscoveryService {
  HdDiscoveryService({KaspaApi? api}) : _api = api ?? KaspaApi();

  static const gapLimit = 20;
  static const maxAddressesPerBranch = 100;
  static const maxAccounts = 10;
  static const discoveryTimeLimit = Duration(seconds: 45);
  static const _coinTypes = [111111, 972];
  final KaspaApi _api;

  Future<String> discoverAndRegister(
    String fallbackAddress,
    NativeSecurity security, {
    void Function(String status)? onProgress,
  }) async {
    try {
      final deadline = DateTime.now().add(discoveryTimeLimit);
      final discovered = <NativeHdAddress>[];
      for (final coinType in _coinTypes) {
        for (var account = 0; account < maxAccounts; account++) {
          if (DateTime.now().isAfter(deadline)) {
            onProgress?.call('Finishing wallet import…');
            break;
          }
          onProgress?.call(
            'Scanning ${coinType == 111111 ? 'Kaspa' : 'legacy'} '
            'account ${account + 1}…',
          );
          final branches = await Future.wait(
            const [0, 1].map(
              (change) => _scanBranch(
                security: security,
                coinType: coinType,
                account: account,
                change: change,
                deadline: deadline,
              ),
            ),
          );
          final accountAddresses = branches.expand((items) => items).toList();
          final hasActivity = accountAddresses.any((item) => item.used);
          if (hasActivity || (coinType == 111111 && account == 0)) {
            discovered.addAll(accountAddresses);
          }
          if (!hasActivity) break;
        }
      }
      if (discovered.isEmpty) return fallbackAddress;
      // Discovery scans ahead by the gap limit, but only addresses that are
      // actually in use (plus each branch's first address) belong in the
      // wallet selector. Keeping every scanned address would make a manually
      // created subwallet start at index 20 instead of index 1.
      final registered = discovered
          .where(
            (item) => item.used || item.index == 0,
          )
          .toList();
      await security.registerHdAddresses(registered);
      final usedReceive = discovered.where(
        (item) => item.used && item.change == 0,
      );
      return usedReceive.isEmpty ? fallbackAddress : usedReceive.first.address;
    } catch (_) {
      // Import remains usable with the standard first address if discovery is
      // temporarily unavailable. It can be run again from wallet management.
      return fallbackAddress;
    }
  }

  Future<List<NativeHdAddress>> _scanBranch({
    required NativeSecurity security,
    required int coinType,
    required int account,
    required int change,
    required DateTime deadline,
  }) async {
    final result = <NativeHdAddress>[];
    var consecutiveUnused = 0;
    for (var start = 0;
        start < maxAddressesPerBranch && consecutiveUnused < gapLimit;
        start += gapLimit) {
      if (DateTime.now().isAfter(deadline)) break;
      final batch = await security.deriveAddresses(
        coinType: coinType,
        account: account,
        change: change,
        start: start,
        count: gapLimit,
      );
      final activity = await Future.wait(
        batch.map(
          (item) => _api
              .addressHasActivity(item.address)
              .timeout(
                deadline.difference(DateTime.now()).isNegative
                    ? Duration.zero
                    : deadline.difference(DateTime.now()),
              )
              .catchError((_) => false),
        ),
      );
      for (var index = 0; index < batch.length; index++) {
        final used = activity[index];
        result.add(batch[index].copyWith(used: used));
        consecutiveUnused = used ? 0 : consecutiveUnused + 1;
      }
    }
    return result;
  }
}
