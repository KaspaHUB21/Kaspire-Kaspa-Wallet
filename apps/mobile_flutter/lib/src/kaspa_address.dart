const _kaspaCharset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

String kaspaOwnerIdFromAddress(String address) {
  final normalized = address.trim().toLowerCase();
  final separator = normalized.indexOf(':');
  if (separator <= 0 || normalized.indexOf(':', separator + 1) != -1) {
    return '';
  }
  final prefixText = normalized.substring(0, separator);
  final encoded = normalized.substring(separator + 1);
  if (prefixText != 'kaspa' || encoded.length < 8) return '';
  final values = <int>[];
  for (final character in encoded.codeUnits) {
    final value = _kaspaCharset.indexOf(String.fromCharCode(character));
    if (value < 0) return '';
    values.add(value);
  }
  final prefix = prefixText.codeUnits.map((value) => value & 31);
  if (_polymod([...prefix, 0, ...values]) != 0) return '';
  final payload = _convert5To8(values.sublist(0, values.length - 8));
  if (payload == null || payload.length != 33 || payload.first != 0) return '';
  return payload
      .skip(1)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String kaspaAddressFromOwnerId(String ownerId) {
  final normalized = ownerId.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) return '';
  final payload = <int>[0];
  for (var index = 0; index < normalized.length; index += 2) {
    payload.add(int.parse(normalized.substring(index, index + 2), radix: 16));
  }
  final fiveBitPayload = _convert8To5(payload);
  final prefix = 'kaspa'.codeUnits.map((value) => value & 31);
  final checksum = _polymod([
    ...prefix,
    0,
    ...fiveBitPayload,
    ...List.filled(8, 0),
  ]);
  final checksumBytes = <int>[
    for (var shift = 32; shift >= 0; shift -= 8) (checksum >> shift) & 0xff,
  ];
  final encoded = [
    ...fiveBitPayload,
    ..._convert8To5(checksumBytes),
  ].map((value) => _kaspaCharset[value]).join();
  return 'kaspa:$encoded';
}

List<int>? _convert5To8(List<int> payload) {
  final result = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final value in payload) {
    if (value < 0 || value > 31) return null;
    buffer = (buffer << 5) | value;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      result.add((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits >= 5 || ((buffer << (8 - bits)) & 0xff) != 0) return null;
  return result;
}

List<int> _convert8To5(List<int> payload) {
  final result = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final byte in payload) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      result.add((buffer >> bits) & 31);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0) result.add((buffer << (5 - bits)) & 31);
  return result;
}

int _polymod(Iterable<int> values) {
  var checksum = 1;
  for (final value in values) {
    final high = checksum >> 35;
    checksum = ((checksum & 0x07ffffffff) << 5) ^ value;
    if (high & 1 != 0) checksum ^= 0x98f2bc8e61;
    if (high & 2 != 0) checksum ^= 0x79b76d99e2;
    if (high & 4 != 0) checksum ^= 0xf33e5fb3c4;
    if (high & 8 != 0) checksum ^= 0xae2eabe2a8;
    if (high & 16 != 0) checksum ^= 0x1e4f43e470;
  }
  return checksum ^ 1;
}
