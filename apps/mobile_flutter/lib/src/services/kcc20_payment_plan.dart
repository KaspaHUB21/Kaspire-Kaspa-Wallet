/// Recovery only replays signed bytes. Never prepares/signs a replacement TX.
Future<Map> runKcc20PaymentPlan(Map<String, Object?> plan, String address,
    {required Future<void> Function(Map<String, Object?>) save,
    required Future<bool> Function(String) accepted,
    required Future<void> Function(String, String) broadcast,
    required Future<void> Function(Map) record,
    required void Function() check,
    void Function(String)? progress,
    Future<void> Function()? pause}) async {
  final transactions = plan['transactions'] as List;
  final next = plan['nextStep'] as int;
  if (plan['sender'] != address ||
      transactions.isEmpty ||
      transactions.length > 32 ||
      next < 0 ||
      next > transactions.length ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(plan['reviewHash'].toString()) ||
      transactions.any((t) =>
          !RegExp(r'^[0-9a-f]{64}$')
              .hasMatch((t as Map)['transactionId'].toString()) ||
          t['signedTxJson'] is! String)) {
    throw StateError('Invalid saved KCC20 payment plan or different wallet.');
  }
  await save(plan);
  for (var i = next; i < transactions.length; i++) {
    check();
    final tx = transactions[i] as Map, id = tx['transactionId'] as String;
    progress?.call(
        'KCC20 payment: transaction ${i + 1} of ${transactions.length}. '
        '${i + 1 < transactions.length ? 'Consolidating own cells; recipient not paid yet.' : 'Sending final recipient payment.'}');
    var confirmed = false;
    try {
      confirmed = await accepted(id);
    } catch (_) {/* Exact replay is safe. */}
    if (!confirmed) {
      try {
        await broadcast(tx['signedTxJson'] as String, id);
      } catch (_) {
        // A timeout may occur after successful submission. Confirm before failing.
        try {
          confirmed = await accepted(id);
        } catch (_) {/* Preserve journal. */}
        if (!confirmed) rethrow;
      }
      for (var attempt = 0; attempt < 12 && !confirmed; attempt++) {
        try {
          confirmed = await accepted(id);
        } catch (_) {/* Confirmation may lag. */}
        if (!confirmed) {
          await (pause?.call() ??
              Future<void>.delayed(const Duration(milliseconds: 1500)));
        }
      }
    }
    if (!confirmed) {
      throw StateError(
          'KCC20 plan saved at transaction ${i + 1}/${transactions.length}. Confirmation pending. Use Continue KCC20 transfer; no new payment will be created.');
    }
    await record(tx);
    await save({...plan, 'nextStep': i + 1});
    plan['nextStep'] = i + 1;
  }
  return transactions.last as Map;
}
