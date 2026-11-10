/// Plain EVM addresses, as encoded by Kaspire's L2 receive QR codes.
/// Payment/function URIs are deliberately not treated as recipient addresses.
class EvmAddress {
  static final _pattern = RegExp(r'^0x[0-9a-fA-F]{40}$');

  static String? tryParse(String value) {
    final address = value.trim();
    return _pattern.hasMatch(address) ? address : null;
  }
}
