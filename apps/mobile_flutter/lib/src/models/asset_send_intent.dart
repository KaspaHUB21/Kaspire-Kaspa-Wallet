import 'wallet_snapshot.dart';

class AssetSendIntent {
  const AssetSendIntent._({
    required this.kind,
    this.symbol,
    this.tokenId,
    this.domainName,
    this.assetId,
    this.wallet,
    this.nft,
  });

  const AssetSendIntent.krc20(String symbol, {WalletSnapshot? wallet})
      : this._(kind: 'krc20', symbol: symbol, wallet: wallet);

  const AssetSendIntent.kcc20(String symbol, String covenantId,
      {WalletSnapshot? wallet})
      : this._(
            kind: 'kcc20', symbol: symbol, assetId: covenantId, wallet: wallet);

  const AssetSendIntent.krc721(String symbol,
      {String? tokenId, WalletSnapshot? wallet, WalletNft? nft})
      : this._(
            kind: 'krc721',
            symbol: symbol,
            tokenId: tokenId,
            wallet: wallet,
            nft: nft);

  const AssetSendIntent.kns(String domainName, String? assetId,
      {WalletSnapshot? wallet})
      : this._(
            kind: 'kns',
            domainName: domainName,
            assetId: assetId,
            wallet: wallet);

  final String kind;
  final String? symbol;
  final String? tokenId;
  final String? domainName;
  final String? assetId;

  /// Display hint only. Signing still reloads and independently verifies inputs.
  final WalletSnapshot? wallet;
  final WalletNft? nft;
}
