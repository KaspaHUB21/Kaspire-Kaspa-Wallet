export function walletUrl(tokenId: string, wallet: string | undefined) {
  if (!wallet || wallet === "unknown") {
    return null;
  }
  if (tokenId.startsWith("l2-kasplex-")) {
    return "/wallet/kasplex/" + encodeURIComponent(wallet);
  }
  if (tokenId.startsWith("l2-igra-")) {
    return "/wallet/igra/" + encodeURIComponent(wallet);
  }
  return "/wallet/krc20/" + encodeURIComponent(wallet);
}

