import 'kaspa_api.dart';
import 'kcc20_standard_service.dart';
import 'native_security.dart';
import '../models/wallet_snapshot.dart';

class DappKcc20Payment {
  const DappKcc20Payment(this.request, this.review, this.ticker, this.decimals,
      this.recipientCellStatus);
  final Map<String, Object?> request, review;
  final String ticker, recipientCellStatus;
  final int decimals;
}

/// Discovery is not spend authority. Resolve only this covenant, then use the
/// same fresh cell proof, borrowed receive and native plan as the send screen.
Future<DappKcc20Payment> prepareDappKcc20Payment({
  required KaspaApi api,
  required NativeSecurity security,
  required String sender,
  required String recipient,
  required String covenantId,
  required int amount,
  required bool Function() isCancelled,
  void Function(String)? onProgress,
}) async {
  void check() {
    if (isCancelled()) throw StateError('KCC20 preparation cancelled.');
  }

  check();
  onProgress?.call('Verifying the requested KCC20 token…');
  final reader = api.standardKcc20;
  final envelope = await reader.get('${reader.base}/tokens/$covenantId',
      isCancelled: isCancelled, priority: true);
  check();
  final token = Kcc20StandardService.map(envelope['data']);
  final template = Kcc20StandardService.tokenTemplate(token);
  final decimals = Kcc20StandardService.verifiedDecimals(token);
  if (Kcc20StandardService.rowId(token) != covenantId ||
      template == null ||
      decimals == null ||
      !['hash_proven_reference_actor_family', 'hash_proven_program_artifact']
          .contains(token['recognition'])) {
    throw StateError(
        'Unsupported or unverified KCC20 covenant or token units.');
  }
  final metadata = Kcc20StandardService.map(token['metadata']);
  if (metadata['binding_verified'] == true &&
      metadata['covenant_id'] != null &&
      metadata['covenant_id'] != covenantId) {
    throw StateError('KCC20 metadata covenant differs.');
  }
  final ticker = (metadata['binding_verified'] == true
          ? metadata['ticker'] ?? metadata['symbol'] ?? 'KCC20_RAW'
          : 'KCC20_RAW')
      .toString()
      .toUpperCase();
  if (!RegExp(r'^[A-Z0-9_.-]{1,32}$').hasMatch(ticker)) {
    throw StateError('Invalid KCC20 ticker.');
  }
  // This typed dApp method supports the pinned reference programs only. Venue
  // owner-only contracts retain their separate send/review implementation.
  if (token['wallet_standard'] == 'kasseal-kcc20') {
    throw StateError('Use the Kasseal token send screen for this contract.');
  }
  final step = await api.loadStandardKcc20SigningBatch(
      sender, covenantId, amount,
      fullPlan: true, isCancelled: isCancelled, onProgress: onProgress);
  check();
  if (step.cells.isEmpty || step.compound || step.templateId != template) {
    throw StateError(
        'The complete KCC20 recipient payment could not be prepared.');
  }
  onProgress
      ?.call('Checking whether an existing recipient cell can be reused…');
  final borrowed = sender == recipient
      ? null
      : await api.loadKcc20BorrowedReceive(
          recipient, covenantId, amount, step.cells.first, template,
          isCancelled: isCancelled);
  check();
  final funding = await api.loadUtxos(sender);
  check();
  Map<String, Object?> cell(Kcc20CellRecord c) => {
        'transactionId': c.transactionId,
        'index': c.index,
        'valueSompi': c.valueSompi,
        'blockDaaScore': c.blockDaaScore,
        'scriptPublicKey': c.scriptPublicKey,
        'tokenAmount': c.tokenAmount,
        'redeemScript': c.redeemScript,
      };
  final request = <String, Object?>{
    'sender': sender,
    'recipient': recipient,
    'covenantId': covenantId,
    'ticker': ticker,
    'amount': amount,
    'decimals': decimals,
    'feeRate': 100.0,
    'templateHash': template,
    'cells': step.cells.map(cell).toList(),
    if (borrowed != null) 'borrowedReceive': cell(borrowed),
    'fundingUtxosJson': funding,
  };
  onProgress
      ?.call('Verifying the complete transaction plan in the native core…');
  final plan = await security.prepareKcc20Plan(request);
  check();
  final steps = (plan['steps'] as List).cast<Map>();
  if (steps.isEmpty || steps.length > 32)
    throw StateError('Invalid KCC20 plan.');
  final last = steps.last;
  final locked = step.cells.fold<int>(0, (sum, c) => sum + c.valueSompi) +
      (borrowed?.valueSompi ?? 0);
  final lockedOut = (last['lockedKasOutputSompi'] as num).toInt();
  return DappKcc20Payment(
      request,
      {
        ...last.cast<String, Object?>(),
        ...plan,
        'feeSompi': plan['totalFeeSompi'],
        'mass': last['feeMass'],
        'lockedKasSompi': locked,
        'lockedKasOutputSompi': lockedOut,
        'lockedKasTopUpSompi': lockedOut > locked ? lockedOut - locked : 0,
        'lockedKasReleasedSompi': locked > lockedOut ? locked - lockedOut : 0,
      },
      ticker,
      decimals,
      borrowed == null ? 'new' : 'reused');
}
