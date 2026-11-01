import 'package:flutter/material.dart';

/// A pending/partial asset lookup must not be presented as a confirmed empty
/// wallet. Positive holdings remain visible while independent sources finish.
class AssetDiscoveryNotice extends StatelessWidget {
  const AssetDiscoveryNotice(
      {super.key,
      required this.empty,
      required this.loading,
      this.complete = true,
      this.warning});
  final bool empty, loading;
  final bool complete;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final incomplete = !complete || warning?.isNotEmpty == true;
    final kcc20Warning = warning?.toLowerCase().contains('kcc20') == true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (empty)
          Text(
              loading
                  ? 'Asset discovery is still loading…'
                  : incomplete
                      ? 'Asset discovery is incomplete. Pull to refresh to retry.'
                      : 'No token, NFT or name assets found for this address.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (kcc20Warning)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(warning!, style: const TextStyle(height: 1.4))),
      ],
    );
  }
}
