class AssetSendIntent {
  const AssetSendIntent._({
    required this.kind,
    this.symbol,
    this.tokenId,
    this.domainName,
    this.assetId,
  });

  const AssetSendIntent.krc20(String symbol)
      : this._(kind: 'krc20', symbol: symbol);

  const AssetSendIntent.kcc20(String symbol, String covenantId)
      : this._(kind: 'kcc20', symbol: symbol, assetId: covenantId);

  const AssetSendIntent.krc721(String symbol, {String? tokenId})
      : this._(kind: 'krc721', symbol: symbol, tokenId: tokenId);

  const AssetSendIntent.kns(String domainName, String? assetId)
      : this._(kind: 'kns', domainName: domainName, assetId: assetId);

  final String kind;
  final String? symbol;
  final String? tokenId;
  final String? domainName;
  final String? assetId;
}
