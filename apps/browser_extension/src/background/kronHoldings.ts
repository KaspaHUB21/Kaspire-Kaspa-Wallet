const INDEXER = 'https://idx.kron.technology/v1/kcc20';
const KASVIO = 'https://kasvio.network';
export type JsonGet = (url: string) => Promise<any>;

export async function kronBalances(get: JsonGet, address: string) {
  const [status, data] = await Promise.all([
    get(`${INDEXER}/info`), get(`${INDEXER}/address/${encodeURIComponent(address)}/tokenlist`),
  ]);
  const info = status?.result;
  if (info?.network !== 'mainnet' || info?.networkOk !== true || info?.synced !== true || info?.divergent === true)
    throw new Error('KRON indexer is not synchronized with mainnet.');
  if (!Array.isArray(data?.result) || data.result.length > 1000)
    throw new Error('Invalid KRON holdings response.');
  const seen = new Set<string>();
  return data.result.filter((row: any) => {
    const id = String(row?.covenantId ?? '').toLowerCase(), raw = String(row?.balance ?? ''), dec = Number(row?.dec);
    if (!/^[0-9a-f]{64}$/.test(id) || !/^\d+$/.test(raw) || !Number.isInteger(dec) || dec < 0 || dec > 18 || seen.has(id))
      throw new Error('Invalid or duplicate KRON holding.');
    seen.add(id);
    return BigInt(raw) > 0n;
  });
}

export async function kronMetadata(get: JsonGet, row: any) {
  const data = await get(`${INDEXER}/token/${encodeURIComponent(row.tick)}`);
  const matches = (Array.isArray(data?.result) ? data.result : []).filter((token: any) =>
    String(token?.covenantId).toLowerCase() === String(row.covenantId).toLowerCase() && Number(token?.dec) === Number(row.dec));
  if (matches.length !== 1) throw new Error('KRON ticker does not resolve to this covenant.');
  return matches[0];
}

export async function directKronAssets(get: JsonGet, address: string) {
  const marketsFuture = get(`${KASVIO}/api/dex?dex=kron&range=7d`).catch(() => null);
  const rows = await kronBalances(get, address), data = await marketsFuture;
  const markets = new Map<string, any>();
  if (data?.stale === false && data?.source?.available === true && Array.isArray(data?.tokens)) {
    for (const token of data.tokens) {
      if (/^[0-9a-f]{64}$/.test(String(token?.id).toLowerCase()))
        markets.set(String(token.id).toLowerCase(), token);
    }
  }
  return rows.map((row: any) => {
    const id = String(row.covenantId).toLowerCase(), market = markets.get(id);
    const price = Number(market?.price), scale = 10 ** Number(row.dec);
    return {
      covenantId: id, symbol: String(row.tick).toUpperCase(), name: String(market?.name ?? row.tick),
      rawBalance: String(row.balance), decimals: Number(row.dec),
      image_url: /^https:\/\//.test(String(market?.logo ?? '')) ? market.logo : '',
      priceKas: Number.isFinite(price) && price >= 0 ? price * scale : null,
      standard: 'kron-native', validationStatus: 'observed', directTransfer: false,
      explorerUrl: 'https://kron.technology/', kronUrl: 'https://kron.technology/',
    };
  });
}

export async function directKronTransfer(get: JsonGet, address: string, covenantId: string, amount: number, nodeBase: string) {
  const rows = await kronBalances(get, address), row = rows.find((item: any) => String(item.covenantId).toLowerCase() === covenantId);
  if (!row || !Number.isSafeInteger(amount) || amount <= 0 || BigInt(amount) > BigInt(row.balance))
    throw new Error('Insufficient KRON token balance.');
  const token = await kronMetadata(get, row);
  const data = await get(`${INDEXER}/token/${encodeURIComponent(row.tick)}/address/${encodeURIComponent(address)}/utxos`);
  if (!Array.isArray(data?.result) || data.result.length > 1000) throw new Error('Invalid KRON signing data.');
  const seen = new Set<string>();
  const candidates = data.result.map((item: any) => {
    const transactionId = String(item?.outpoint?.transactionId ?? '').toLowerCase(), index = item?.outpoint?.index,
      tokenAmount = Number(item?.amount), redeemScript = String(item?.redeemScriptHex ?? '').toLowerCase(),
      scriptPublicKey = String(item?.scriptPublicKey ?? '').toLowerCase().replace(/^0000/, ''), key = `${transactionId}:${index}`;
    if (!/^[0-9a-f]{64}$/.test(transactionId) || !Number.isSafeInteger(index) || index < 0 ||
        !Number.isSafeInteger(tokenAmount) || tokenAmount <= 0 || item?.ownerAddress !== address ||
        !/^(?:[0-9a-f]{2})+$/.test(redeemScript) || !/^(?:[0-9a-f]{2})+$/.test(scriptPublicKey) || seen.has(key))
      throw new Error('Invalid or duplicate KRON signing cell.');
    seen.add(key);
    return {transactionId, index, tokenAmount, redeemScript, scriptPublicKey};
  }).sort((a: any, b: any) => b.tokenAmount - a.tokenAmount);
  const selected: any[] = [];
  let total = 0;
  for (const cell of candidates.slice(0, 4)) {
    selected.push(cell); total += cell.tokenAmount;
    if (total >= amount) break;
  }
  if (total < amount) throw new Error('This transfer needs more than four spendable KRON cells. Reduce the amount or consolidate in KRON.');
  for (const cell of selected) {
    const tx = await get(`${nodeBase}/local-node/transactions/${cell.transactionId}`);
    const output = (Array.isArray(tx?.outputs) ? tx.outputs : []).find((item: any) => item?.index === cell.index);
    const outputAddress = String(output?.script_public_key_address ?? output?.address ?? '');
    const script = String(output?.script_public_key ?? output?.scriptPublicKey ?? '').toLowerCase().replace(/^0000/, '');
    if (String(tx?.transaction_id).toLowerCase() !== cell.transactionId || tx?.is_accepted !== true ||
        String(output?.covenant_id).toLowerCase() !== covenantId || script !== cell.scriptPublicKey ||
        !Number.isSafeInteger(Number(output?.amount)) || Number(output?.amount) <= 0 || !/^kaspa:[a-z0-9]{61,63}$/.test(outputAddress))
      throw new Error('KRON indexer data conflicts with the local Kaspa node.');
    const live = await get(`${nodeBase}/local-node/addresses/${encodeURIComponent(outputAddress)}/utxos`);
    if (!Array.isArray(live) || !live.some((item: any) => {
      const outpoint = item?.outpoint, entry = item?.utxoEntry, spk = entry?.scriptPublicKey;
      const liveScript = String(typeof spk === 'object' ? (spk?.scriptPublicKey ?? spk?.script_public_key) : spk ?? '').toLowerCase().replace(/^0000/, '');
      return outpoint?.transactionId === cell.transactionId && outpoint?.index === cell.index &&
        Number(entry?.amount) === Number(output.amount) && liveScript === script && entry?.isCoinbase !== true;
    })) throw new Error('This KRON output is already spent or pending. Refresh and try again.');
    // KRON `amount` is tokens, not native KAS. Only the node supplies value.
    cell.value = Number(output.amount);
  }
  return {ticker: String(row.tick).toUpperCase(), decimals: Number(row.dec), rawBalance: String(row.balance),
    standard: 'kron-native', templateHash: String(token.templateVersion ?? ''), cells: selected};
}
