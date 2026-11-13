import 'dart:convert';

class DappPsktRequest {
  const DappPsktRequest(this.request, this.normalizedResponse);
  final Map<String, Object?> request;
  final bool normalizedResponse;
}

/// Normalize only the public dApp envelope. The native core remains responsible
/// for strict script schemas, bounded witnesses, review binding and signing.
DappPsktRequest normalizeDappPsktRequest(
    Map<String, Object?> params, String sender) {
  void known(Map fields, Set<String> allowed, String path) {
    for (final key in fields.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('Unknown PSKT field $path$key.');
      }
    }
  }

  known(
      params,
      {
        'txJsonString',
        'psktTransactionJson',
        'options',
        'signInputs',
        'scripts',
        'submitTransaction'
      },
      '');
  final tx = params['psktTransactionJson'] ?? params['txJsonString'];
  if (tx is! String || tx.isEmpty || utf8.encode(tx).length > 512 * 1024) {
    throw const FormatException(
        'PSKT transaction JSON must be a non-empty string of at most 512 KiB.');
  }
  final rawOptions = params['options'];
  if (rawOptions != null && rawOptions is! Map) {
    throw const FormatException('PSKT options must be an object.');
  }
  final options = rawOptions == null
      ? <String, Object?>{}
      : (rawOptions as Map)
          .map((key, value) => MapEntry(key.toString(), value));
  known(options, {'signInputs', 'scripts'}, 'options.');
  final inputs = params['signInputs'] ?? options['signInputs'] ?? const [];
  final scripts = params['scripts'] ?? options['scripts'] ?? const [];
  final submit = params['submitTransaction'] ?? false;
  if (submit is! bool) {
    throw const FormatException('PSKT submitTransaction must be a boolean.');
  }
  if (submit) {
    throw const FormatException(
        'Wallet-side PSKT broadcast is not enabled. Request sign-only and broadcast the returned PSKT through the dApp backend.');
  }
  if (inputs is! List)
    throw const FormatException('PSKT signInputs must be a list.');
  if (scripts is! List)
    throw const FormatException('PSKT scripts must be a list.');
  if (inputs.length > 256 ||
      scripts.length > 256 ||
      (inputs.isEmpty && scripts.isEmpty)) {
    throw const FormatException(
        'PSKT selection must contain 1–256 inputs or scripts.');
  }
  final normalizedInputs = <Map<String, Object?>>[];
  for (var i = 0; i < inputs.length; i++) {
    final raw = inputs[i], path = 'signInputs[$i].';
    if (raw is! Map)
      throw FormatException('PSKT signInputs[$i] must be an object.');
    known(raw, {'index', 'sighashType', 'expectedSighash'}, path);
    final index = raw['index'],
        sighash = raw['sighashType'] ?? 1,
        expected = raw['expectedSighash'];
    if (index is! int || index < 0 || index > 255)
      throw FormatException(
          'PSKT ${path}index must be an integer from 0 to 255.');
    if (sighash is! int || !const {1, 2, 4, 129, 130, 132}.contains(sighash))
      throw FormatException(
          'PSKT ${path}sighashType must be a supported integer signing mode.');
    if (expected != null &&
        (expected is! String ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)))
      throw FormatException(
          'PSKT ${path}expectedSighash must be a 32-byte hex string.');
    normalizedInputs.add({
      'index': index,
      'sighashType': sighash,
      if (expected != null) 'expectedSighash': expected
    });
  }
  final normalizedScripts = <Map<String, Object?>>[];
  for (var i = 0; i < scripts.length; i++) {
    final script = scripts[i];
    if (script is! Map)
      throw FormatException('PSKT scripts[$i] must be an object.');
    // Preserve every field for the native deny_unknown_fields validator.
    normalizedScripts
        .add(script.map((key, value) => MapEntry(key.toString(), value)));
  }
  return DappPsktRequest(
      {
        'sender': sender,
        'txJsonString': tx,
        'signInputs': normalizedInputs,
        'scripts': normalizedScripts
      },
      params.containsKey('psktTransactionJson') ||
          params.containsKey('submitTransaction'));
}
