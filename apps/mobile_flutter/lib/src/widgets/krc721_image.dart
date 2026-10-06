import 'package:flutter/material.dart';

/// Only a failed local NFT image may select the independent public cache.
class Krc721Image extends StatelessWidget {
  const Krc721Image(this.url,
      {super.key,
      this.fit = BoxFit.contain,
      this.placeholder = const Icon(Icons.image_not_supported_outlined)});
  final String url;
  final BoxFit fit;
  final Widget placeholder;
  static String? fallback(String url) {
    final uri = Uri.tryParse(url);
    if (uri?.host != 'kaspire.kaslab.space') return null;
    final parts = uri!.pathSegments;
    if (parts.length != 4 ||
        parts[0] != 'krc721-read-v1' ||
        parts[1] != 'images' ||
        !RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(parts[2]) ||
        !RegExp(r'^\d{1,20}$').hasMatch(parts[3])) {
      return null;
    }
    return 'https://krc721-cache.kaspa.com/krc721/mainnet/optimized/${parts[2].toLowerCase()}/${parts[3]}';
  }

  @override
  Widget build(BuildContext context) =>
      Image.network(url, fit: fit, errorBuilder: (_, __, ___) {
        final remote = fallback(url);
        return remote == null
            ? placeholder
            : Image.network(remote,
                fit: fit, errorBuilder: (_, __, ___) => placeholder);
      });
}
