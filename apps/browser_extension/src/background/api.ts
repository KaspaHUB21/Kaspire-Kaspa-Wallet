const MAINNET = "https://kaspire.kaslab.space/api";
const TN10 = "https://api-tn10.kaspa.org";
async function request(
  url: string,
  init: RequestInit = {},
  timeoutMs = 12_000,
) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    if (!response.ok) {
      const parsed = new URL(url);
      throw new Error(
        `Network request failed (${response.status}) for ${parsed.hostname}${parsed.pathname}.`,
      );
    }
    return await response.json();
  } catch (error) {
    if ((error as Error)?.name === "AbortError")
      throw new Error("Live data request timed out. Try again.");
    throw error;
  } finally {
    clearTimeout(timer);
  }
}
async function get(url: string) {
  return request(url, { headers: { accept: "application/json" } });
}
async function post(url: string, body: unknown) {
  return request(url, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
function base(network: "mainnet" | "testnet-10") {
  return network === "mainnet" ? MAINNET : TN10;
}
export async function spendingData(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const endpoint = base(network);
  const [utxos, estimate] = await Promise.all([
    get(`${endpoint}/addresses/${encodeURIComponent(address)}/utxos`),
    get(`${endpoint}/info/fee-estimate`),
  ]);
  if (!Array.isArray(utxos)) throw new Error("Node returned invalid UTXOs.");
  const seen = new Set<string>();
  for (const item of utxos) {
    const id = String(item?.outpoint?.transactionId ?? "");
    const index = Number(item?.outpoint?.index);
    const amount = Number(item?.utxoEntry?.amount);
    if (
      !/^[0-9a-f]{64}$/.test(id) ||
      !Number.isSafeInteger(index) ||
      index < 0 ||
      !Number.isSafeInteger(amount) ||
      amount <= 0 ||
      seen.has(`${id}:${index}`)
    )
      throw new Error("Node returned an invalid or duplicate UTXO.");
    seen.add(`${id}:${index}`);
  }
  const raw = Number(estimate?.priorityBucket?.feerate);
  if (!Number.isFinite(raw) || raw < 0 || raw > 100_000_000)
    throw new Error("Node returned an invalid fee estimate.");
  return { utxosJson: JSON.stringify(utxos), feeRate: Math.max(100, raw) };
}
export async function walletHistory(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const value = await get(
    `${base(network)}/addresses/${encodeURIComponent(address)}/full-transactions?limit=50&offset=0&resolve_previous_outpoints=light`,
  );
  const rows = Array.isArray(value)
    ? value
    : Array.isArray(value?.transactions)
      ? value.transactions
      : [];
  return rows
    .filter((item: any) =>
      /^[0-9a-f]{64}$/.test(
        String(item?.transaction_id ?? item?.transactionId ?? item?.id ?? ""),
      ),
    )
    .map((item: any) => {
      const inputs = Array.isArray(item.inputs) ? item.inputs : [],
        outputs = Array.isArray(item.outputs) ? item.outputs : [];
      const inputTotal = inputs.reduce(
          (sum: number, row: any) =>
            sum + Number(row?.previous_outpoint_amount ?? 0),
          0,
        ),
        outputTotal = outputs.reduce(
          (sum: number, row: any) => sum + Number(row?.amount ?? 0),
          0,
        );
      const walletInput = inputs
          .filter((row: any) => row?.previous_outpoint_address === address)
          .reduce(
            (sum: number, row: any) =>
              sum + Number(row?.previous_outpoint_amount ?? 0),
            0,
          ),
        walletOutput = outputs
          .filter((row: any) => row?.script_public_key_address === address)
          .reduce((sum: number, row: any) => sum + Number(row?.amount ?? 0), 0);
      const incoming = walletInput === 0 && walletOutput > 0;
      const feeSompi = Math.max(0, inputTotal - outputTotal);
      const externalOutputs = outputs.filter(
        (row: any) => row?.script_public_key_address !== address,
      );
      const amountSompi = incoming
        ? walletOutput
        : externalOutputs.reduce(
            (sum: number, row: any) => sum + Number(row?.amount ?? 0),
            0,
          );
      return {
        transactionId: String(
          item.transaction_id ?? item.transactionId ?? item.id,
        ),
        blockTime: Number(item.block_time ?? item.blockTime ?? 0),
        isAccepted: item.is_accepted !== false,
        incoming,
        assetKind: "KAS",
        assetSymbol: "KAS",
        amountSompi,
        displayAmount: `${amountSompi / 100_000_000}`,
        counterparty: incoming
          ? String(
              inputs.find((row: any) => row?.previous_outpoint_address)
                ?.previous_outpoint_address ?? "",
            )
          : String(
              externalOutputs.find((row: any) => row?.script_public_key_address)
                ?.script_public_key_address ?? "",
            ),
        from: inputs
          .map((row: any) => ({
            address: String(row?.previous_outpoint_address ?? ""),
            amountSompi: Number(row?.previous_outpoint_amount ?? 0),
            ownerId: String(row?.covenant_id ?? ""),
          }))
          .filter((row: any) => row.address),
        to: outputs
          .map((row: any) => ({
            address: String(row?.script_public_key_address ?? ""),
            amountSompi: Number(row?.amount ?? 0),
            ownerId: String(row?.covenant_id ?? ""),
          }))
          .filter((row: any) => row.address),
        feeSompi,
        totalInputSompi: inputTotal,
        totalOutputSompi: outputTotal,
        inputCount: inputs.length,
        outputCount: outputs.length,
        blockDaaScore: Number(item.accepting_block_blue_score ?? 0),
        isCoinbase: inputs.length === 0,
        inputs,
        outputs,
        mass: Number(item.mass ?? 0),
        payload: String(item.payload ?? ""),
      };
    });
}
export async function marketPrice(currency: string) {
  const price = await get(`${MAINNET}/info/price`);
  const kasUsd = Number(price?.price);
  if (!Number.isFinite(kasUsd) || kasUsd < 0)
    throw new Error("Node returned an invalid market price.");
  if (currency === "USD") return { kasUsd, rate: 1, currency };
  const rates = await get("https://open.er-api.com/v6/latest/USD");
  const rate = Number(rates?.rates?.[currency]);
  if (!Number.isFinite(rate) || rate <= 0)
    throw new Error("Selected currency rate is unavailable.");
  return { kasUsd, rate, currency };
}
const marketCache = new Map<string, { at: number; value: any }>();
export async function tokenMarket(tokenId: string, symbol: string) {
  if (
    !/^[a-z0-9_-]{1,128}$/i.test(tokenId) ||
    !/^[a-z0-9_-]{1,32}$/i.test(symbol)
  )
    throw new Error("Invalid token market request.");
  const normalized = tokenId.toLowerCase().startsWith("krc20-")
    ? tokenId.toLowerCase()
    : `krc20-${tokenId.toLowerCase()}`;
  const cached = marketCache.get(normalized);
  if (cached && Date.now() - cached.at < 300_000) return cached.value;
  const value = await get(
    `https://kaspatoken.kaslab.space/api/token/${encodeURIComponent(normalized)}`,
  );
  const data = value?.data && typeof value.data === "object" ? value.data : {};
  const priceKas = Number(data.price_kas);
  const priceUsd = Number(data.price_usd);
  const result = {
    tokenId: normalized,
    symbol: symbol.toUpperCase(),
    imageUrl:
      typeof data.image_url === "string"
        ? new URL(data.image_url, "https://kaspatoken.kaslab.space").href
        : "",
    priceKas: Number.isFinite(priceKas) && priceKas >= 0 ? priceKas : null,
    priceUsd: Number.isFinite(priceUsd) && priceUsd >= 0 ? priceUsd : null,
    explorerUrl: `https://kaspatoken.kaslab.space/token/${encodeURIComponent(normalized)}`,
  };
  marketCache.set(normalized, { at: Date.now(), value: result });
  return result;
}
export async function nftCollection(
  address: string,
  ticker: string,
  offset = 0,
) {
  if (
    !/^(kaspa|kaspatest):[a-z0-9]{61,63}$/.test(address) ||
    !/^[A-Z0-9_-]{1,32}$/.test(ticker) ||
    !Number.isSafeInteger(offset) ||
    offset < 0
  )
    throw new Error("Invalid NFT collection request.");
  const value = await get(
    `https://kaspatoken.kaslab.space/api/wallet/krc20/${encodeURIComponent(address)}/krc721/${encodeURIComponent(ticker)}?limit=48&offset=${offset}`,
  );
  const data = value?.data && typeof value.data === "object" ? value.data : {};
  const rows = Array.isArray(data.nfts) ? data.nfts : [];
  return {
    ticker: String(data.ticker ?? ticker).toUpperCase(),
    total: Number(data.total ?? rows.length),
    nextOffset: Number.isSafeInteger(data.next_offset)
      ? data.next_offset
      : null,
    nfts: rows
      .map((item: any) => ({
        ticker: String(item?.ticker ?? ticker).toUpperCase(),
        tokenId: String(item?.token_id ?? ""),
        imageUrl: typeof item?.image_url === "string" ? item.image_url : "",
        rarityRank: Number.isSafeInteger(item?.rarity_rank)
          ? item.rarity_rank
          : null,
        nexusUrl: typeof item?.nexus_url === "string" ? item.nexus_url : "",
      }))
      .filter((item: any) => item.tokenId),
  };
}
export async function nftRarity(ticker: string, tokenId: string) {
  if (!/^[A-Z0-9_-]{1,32}$/.test(ticker) || !tokenId || tokenId.length > 128)
    throw new Error("Invalid NFT metadata request.");
  const value = await post("https://api.kaspa.com/krc721/tokens", {
    ticker,
    limit: 1,
    offset: 0,
    sortField: "tokenId",
    sortDirection: "asc",
    traits: {},
    tokenIds: [tokenId],
  });
  const item = (Array.isArray(value?.items) ? value.items : []).find(
    (row: any) => String(row?.tokenId ?? "") === tokenId,
  );
  const rank = Number(item?.rarityRank);
  return { rarityRank: Number.isSafeInteger(rank) && rank > 0 ? rank : null };
}
export async function resolveWalletInput(
  input: string,
  network: "mainnet" | "testnet-10",
) {
  const normalized = input.trim().toLowerCase();
  const prefix = network === "mainnet" ? "kaspa" : "kaspatest";
  if (new RegExp(`^${prefix}:[a-z0-9]{61,63}$`).test(normalized))
    return normalized;
  if (network !== "mainnet" || !/^[a-z0-9][a-z0-9.-]*\.kas$/.test(normalized))
    throw new Error(
      network === "mainnet"
        ? "Enter a Kaspa address or valid name.kas domain."
        : "Enter a valid TN10 kaspatest: address.",
    );
  const value = await loadTokenAssets(normalized);
  const address = String(value?.data?.address ?? "").toLowerCase();
  if (!/^kaspa:[a-z0-9]{61,63}$/.test(address))
    throw new Error("KNS domain not found or it has no Kaspa owner.");
  return address;
}
export async function broadcast(
  submitJson: string,
  network: "mainnet" | "testnet-10",
) {
  const response = await fetch(`${base(network)}/transactions`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: submitJson,
  });
  if (!response.ok) throw new Error(`Broadcast rejected (${response.status}).`);
  const value = await response.json();
  const id = String(value?.transactionId ?? value?.transaction_id ?? "");
  if (id && !/^[0-9a-f]{64}$/.test(id))
    throw new Error("Node returned an invalid transaction ID.");
  return id;
}
export async function waitForUtxo(
  address: string,
  transactionId: string,
  network: "mainnet" | "testnet-10",
) {
  for (let attempt = 0; attempt < 40; attempt++) {
    try {
      const utxos = await get(
        `${base(network)}/addresses/${encodeURIComponent(address)}/utxos`,
      );
      if (
        Array.isArray(utxos) &&
        utxos.some(
          (item: any) => item?.outpoint?.transactionId === transactionId,
        )
      )
        return JSON.stringify(utxos);
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error("Commit is accepted but not spendable yet.");
}
export async function verifyKrc721Ownership(
  address: string,
  ticker: string,
  tokenId: string,
) {
  let offset = "";
  for (let page = 0; page < 100; page++) {
    const query = new URLSearchParams({
      limit: "500",
      direction: "forward",
      ...(offset ? { offset } : {}),
    });
    const value = await get(
      `https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet/address/${encodeURIComponent(address)}?${query}`,
    );
    const items = Array.isArray(value?.result) ? value.result : [];
    if (
      items.some(
        (item: any) =>
          String(item?.tick ?? "").toUpperCase() === ticker &&
          String(item?.tokenId ?? "") === tokenId,
      )
    )
      return true;
    const next = typeof value?.next === "string" ? value.next : "";
    if (!next || !items.length) return false;
    offset = next;
  }
  throw new Error("KRC-721 ownership result exceeded the safe page limit.");
}
const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function ownerId(address: string) {
  const [prefix, encoded, ...rest] = address.toLowerCase().split(":");
  if (rest.length || prefix !== "kaspa" || !encoded) return "";
  const values = [...encoded].map((char) => CHARSET.indexOf(char));
  if (values.some((value) => value < 0)) return "";
  let checksum = 1n;
  for (const value of [
    ...[...prefix].map((char) => char.charCodeAt(0) & 31),
    0,
    ...values,
  ]) {
    const high = checksum >> 35n;
    checksum = ((checksum & 0x07ffffffffn) << 5n) ^ BigInt(value);
    for (const [bit, constant] of [
      [1n, 0x98f2bc8e61n],
      [2n, 0x79b76d99e2n],
      [4n, 0xf33e5fb3c4n],
      [8n, 0xae2eabe2a8n],
      [16n, 0x1e4f43e470n],
    ] as const)
      if (high & bit) checksum ^= constant;
  }
  if ((checksum ^ 1n) !== 0n) return "";
  let buffer = 0,
    bits = 0;
  const bytes: number[] = [];
  for (const value of values.slice(0, -8)) {
    buffer = (buffer << 5) | value;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 255);
      buffer &= (1 << bits) - 1;
    }
  }
  return bytes.length === 33 && bytes[0] === 0
    ? bytes
        .slice(1)
        .map((value) => value.toString(16).padStart(2, "0"))
        .join("")
    : "";
}
function verifiedKcc20Standard(token: any) {
  const standard = String(token?.standard ?? "").toLowerCase(),
    status = String(token?.validation_status ?? "").toLowerCase();
  if (
    (standard === "kron-native" || token?.contract_type === "kron-native") &&
    status === "template_verified"
  )
    return "kron-native";
  if ((!standard || standard === "legacy-kcc20") && status === "verified")
    return "legacy-kcc20";
  return "";
}
async function loadKcc20Assets(address: string) {
  const owner = ownerId(address);
  if (!owner) return [];
  const [status, balances] = await Promise.all([
    get("https://kcc20.info/v1/status"),
    get(`https://kcc20.info/v1/owners/${owner}/balances?limit=1000`),
  ]);
  if (status?.capabilities?.balances !== true || Number(status?.max_daa) <= 0)
    throw new Error("KCC20 indexer is not ready.");
  const rows = (Array.isArray(balances?.balances) ? balances.balances : [])
    .filter(
      (item: any) =>
        (item?.validation_status === "verified" ||
          item?.validation_status === "template_verified") &&
        Number(item?.unresolved_cells) === 0 &&
        Number(item?.balance) > 0,
    )
    .slice(0, 1000);
  return (
    await Promise.all(
      rows.map(async (item: any) => {
        const id = String(item.token_id ?? "").toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(id))
          throw new Error("Invalid KCC20 covenant ID.");
        const token = await get(`https://kcc20.info/v1/tokens/${id}`);
        const decimals = Number(
            token?.decimals ?? token?.claimed_decimals ?? 8,
          ),
          standard = verifiedKcc20Standard(token);
        if (
          !Number.isInteger(decimals) ||
          decimals < 0 ||
          decimals > 18 ||
          !standard
        )
          throw new Error("Invalid KCC20 metadata.");
        const claimedImage = String(token?.image ?? token?.claimed_image ?? ""),
          imageApi = String(token?.image_api ?? "");
        const image = /^https:\/\//.test(claimedImage)
          ? claimedImage
          : imageApi.startsWith("/v1/tokens/")
            ? `https://kcc20.info${imageApi}`
            : "";
        return {
          covenantId: id,
          symbol: String(
            token?.ticker ??
              token?.claimed_name ??
              token?.name ??
              token?.fallback_name ??
              "KCC20",
          ).toUpperCase(),
          name: String(
            token?.name ??
              token?.claimed_name ??
              token?.fallback_name ??
              "KCC20",
          ),
          rawBalance: String(item.balance),
          decimals,
          image_url: image,
          standard,
          contractType: String(token?.contract_type ?? ""),
          validationStatus: String(token?.validation_status ?? ""),
          directTransfer: standard === "legacy-kcc20",
          explorerUrl: `https://kcc20.info/token/${id}`,
          kronUrl: standard === "kron-native" ? "https://kron.technology/" : "",
        };
      }),
    )
  ).filter(Boolean);
}
export function mapKcc20Cells(
  cellsData: any,
  covenantId: string,
  owner: string,
  rawBalance: number,
  templateHash: string,
) {
  const rows = (Array.isArray(cellsData?.cells) ? cellsData.cells : []).filter(
    (item: any) =>
      String(item?.token_id ?? item?.covenant_id).toLowerCase() ===
        covenantId && item?.signing_ready !== false,
  );
  const cells = rows.flatMap((item: any) => {
    const state =
      item?.state && typeof item.state === "object" ? item.state : {};
    const stateFields = Array.isArray(state?.state_fields)
      ? state.state_fields
      : Array.isArray(item?.state_fields)
        ? item.state_fields
        : [];
    const field = (name: string) =>
      stateFields.find((entry: any) => String(entry?.name) === name)?.value;
    const cellOwner = String(
      item?.owner ?? state?.owner ?? field("owner_identifier") ?? "",
    ).toLowerCase();
    if (cellOwner && cellOwner !== owner) return [];
    const tokenAmount = Number(
      item?.token_amount ?? item?.amount ?? state?.amount,
    );
    return [
      {
        covenantId,
        transactionId: String(
          item?.outpoint_tx_id ?? item?.transaction_id ?? item?.txid ?? "",
        ).toLowerCase(),
        index: Number(
          item?.outpoint_index ?? item?.index ?? item?.output_index,
        ),
        valueSompi: Number(item?.value),
        blockDaaScore: Number(item?.created_daa),
        scriptPublicKey: normalizeKcc20Script(
          item?.script_public_key ?? item?.script_hex,
        ),
        tokenAmount,
        isMinter: item?.is_minter === true || state?.is_minter === true,
      },
    ];
  });
  const hasUnmapped = (
    Array.isArray(cellsData?.unmapped) ? cellsData.unmapped : []
  ).some(
    (item: any) =>
      String(item?.token_id ?? item?.covenant_id).toLowerCase() === covenantId,
  );
  const seen = new Set<string>();
  if (
    hasUnmapped ||
    !/^[0-9a-f]{64}$/.test(templateHash) ||
    !cells.length ||
    cells.some((cell: any) => {
      const outpoint = `${cell.transactionId}:${cell.index}`;
      const invalid =
        !/^[0-9a-f]{64}$/.test(cell.transactionId) ||
        !Number.isSafeInteger(cell.index) ||
        cell.index < 0 ||
        !Number.isSafeInteger(cell.valueSompi) ||
        cell.valueSompi <= 0 ||
        !Number.isSafeInteger(cell.tokenAmount) ||
        cell.tokenAmount <= 0 ||
        !/^[0-9a-f]+$/i.test(cell.scriptPublicKey) ||
        seen.has(outpoint);
      seen.add(outpoint);
      return invalid;
    }) ||
    cells.reduce((sum: number, cell: any) => sum + cell.tokenAmount, 0) !==
      rawBalance
  )
    throw new Error("KCC20 cell discovery is incomplete.");
  return cells;
}

export function normalizeKcc20Script(value: unknown) {
  const script = String(value ?? "").toLowerCase();
  return /^0000aa20[0-9a-f]{64}87$/.test(script) ? script.slice(4) : script;
}

async function loadKascovKcc20Cells(
  covenantId: string,
  owner: string,
  rawBalance: number,
) {
  const [detail, coin] = await Promise.all([
    get(`https://kascov.io/data/mainnet/token/${covenantId}`),
    get(`https://kascov.io/data/mainnet/c/${covenantId}.json`),
  ]);
  const balance = (Array.isArray(detail?.balances) ? detail.balances : []).find(
    (item: any) => String(item?.owner).toLowerCase() === owner,
  );
  if (
    !Number.isSafeInteger(Number(balance?.balance)) ||
    Number(balance.balance) !== rawBalance ||
    coin?.lineage_complete === false
  )
    throw new Error("KCC20 fallback conflicts with the primary balance.");
  const amounts = new Map<string, number>();
  for (const event of Array.isArray(detail?.events) ? detail.events : []) {
    if (String(event?.owner_to).toLowerCase() !== owner) continue;
    const txid = String(event?.txid ?? "").toLowerCase(),
      index = Number(event?.delta_idx ?? event?.output_index ?? event?.index),
      value = Number(event?.balance_to ?? event?.state_amount ?? event?.amount);
    if (
      /^[0-9a-f]{64}$/.test(txid) &&
      Number.isSafeInteger(index) &&
      index >= 0 &&
      Number.isSafeInteger(value) &&
      value > 0
    )
      amounts.set(`${txid}:${index}`, value);
  }
  const liveRows =
    [coin?.live_utxos, coin?.live_outputs, coin?.utxos].find(Array.isArray) ??
    [];
  const rows = [];
  for (const item of liveRows) {
    if (!item || item.live === false) continue;
    const outpoint = typeof item.outpoint === "string" ? item.outpoint : "";
    const parts = outpoint.split(":");
    const nested =
      item.outpoint && typeof item.outpoint === "object" ? item.outpoint : {};
    const txid = String(
      nested.transaction_id ??
        nested.transactionId ??
        item.transaction_id ??
        item.txid ??
        parts[0] ??
        "",
    ).toLowerCase();
    const index = Number(
      nested.index ?? item.index ?? item.output_index ?? parts[1],
    );
    const tokenAmount = amounts.get(`${txid}:${index}`);
    if (tokenAmount === undefined) continue;
    const script = String(
      item.script_hex ??
        item?.script_public_key?.script ??
        item?.scriptPublicKey?.scriptPublicKey ??
        "",
    ).toLowerCase();
    rows.push({
      covenant_id: covenantId,
      outpoint_tx_id: txid,
      outpoint_index: index,
      value: Number(item.value ?? item.amount),
      created_daa: Number(item.created_daa ?? item.block_daa_score),
      script_public_key: script,
      state: { owner, amount: tokenAmount, is_minter: item.is_minter === true },
      signing_ready: true,
    });
  }
  const templateHash = String(coin?.kcc1_template_hash ?? "").toLowerCase();
  return {
    templateHash,
    cells: mapKcc20Cells(
      { cells: rows, unmapped: [] },
      covenantId,
      owner,
      rawBalance,
      templateHash,
    ),
  };
}

async function loadKcc20CellTransaction(transactionId: string) {
  try {
    return await get(`${MAINNET}/local-node/transactions/${transactionId}`);
  } catch (error) {
    if (!String((error as Error)?.message ?? error).includes("(404)"))
      throw error;
    return get(`https://api.kaspa.org/transactions/${transactionId}`);
  }
}

export async function kcc20TransferData(
  address: string,
  covenantId: string,
  amount: number,
) {
  const owner = ownerId(address);
  if (
    !owner ||
    !/^[0-9a-f]{64}$/.test(covenantId) ||
    !Number.isSafeInteger(amount) ||
    amount <= 0
  )
    throw new Error("Invalid KCC20 request.");
  const [status, balances, cellsData, token] = await Promise.all([
    get("https://kcc20.info/v1/status"),
    get(`https://kcc20.info/v1/owners/${owner}/balances?limit=1000`),
    get(
      `https://kcc20.info/v1/owners/${owner}/cells?signing_ready=true&limit=1000`,
    ),
    get(`https://kcc20.info/v1/tokens/${covenantId}`),
  ]);
  if (
    status?.capabilities?.balances !== true ||
    status?.capabilities?.signing_data !== true ||
    Number(status?.max_daa) <= 0
  )
    throw new Error("KCC20 indexer lacks verified signing data.");
  const balance = (
    Array.isArray(balances?.balances) ? balances.balances : []
  ).find(
    (item: any) =>
      String(item?.token_id).toLowerCase() === covenantId &&
      item?.validation_status === "verified" &&
      Number(item?.unresolved_cells) === 0,
  );
  const rawBalance = Number(balance?.balance);
  if (
    !Number.isSafeInteger(rawBalance) ||
    rawBalance <= 0 ||
    amount > rawBalance
  )
    throw new Error("Insufficient verified KCC20 balance.");
  if (
    token?.validation_status !== "verified" ||
    Number(token?.unresolved_cells) > 0
  )
    throw new Error("KCC20 token is not fully verified.");
  let templateHash = String(
    token?.template_hash ?? token?.kcc1_template_hash ?? "",
  ).toLowerCase();
  let cells: any[];
  try {
    if (!/^[0-9a-f]{64}$/.test(templateHash)) {
      const coin = await get(
        `https://kascov.io/data/mainnet/c/${covenantId}.json`,
      );
      templateHash = String(coin?.kcc1_template_hash ?? "").toLowerCase();
      if (coin?.lineage_complete === false)
        throw new Error("KCC20 fallback lineage is incomplete.");
    }
    cells = mapKcc20Cells(
      cellsData,
      covenantId,
      owner,
      rawBalance,
      templateHash,
    );
  } catch {
    const fallback = await loadKascovKcc20Cells(covenantId, owner, rawBalance);
    templateHash = fallback.templateHash;
    cells = fallback.cells;
  }
  for (const cell of cells) {
    const tx = await loadKcc20CellTransaction(cell.transactionId);
    const output = (Array.isArray(tx?.outputs) ? tx.outputs : []).find(
      (item: any) => Number(item?.index) === cell.index,
    );
    const script = normalizeKcc20Script(
      output?.script_public_key ?? output?.scriptPublicKey,
    );
    const outputAddress = String(
      output?.script_public_key_address ?? output?.address ?? "",
    );
    if (
      String(tx?.transaction_id ?? "").toLowerCase() !== cell.transactionId ||
      tx?.is_accepted !== true ||
      String(output?.covenant_id ?? "").toLowerCase() !== covenantId ||
      Number(output?.amount) !== cell.valueSompi ||
      script !== cell.scriptPublicKey ||
      !/^kaspa:[a-z0-9]{61,63}$/.test(outputAddress)
    )
      throw new Error("KCC20 indexer conflicts with the verified transaction.");
    const live = await get(
      `${MAINNET}/local-node/addresses/${encodeURIComponent(outputAddress)}/utxos`,
    );
    const isLive =
      Array.isArray(live) &&
      live.some((item: any) => {
        const outpoint = item?.outpoint ?? {},
          entry = item?.utxoEntry ?? {},
          liveScript = normalizeKcc20Script(
            typeof entry?.scriptPublicKey === "object"
              ? (entry.scriptPublicKey?.scriptPublicKey ??
                  entry.scriptPublicKey?.script_public_key)
              : entry?.scriptPublicKey,
          );
        return (
          String(
            outpoint?.transactionId ?? outpoint?.transaction_id ?? "",
          ).toLowerCase() === cell.transactionId &&
          Number(outpoint?.index) === cell.index &&
          Number(entry?.amount) === cell.valueSompi &&
          liveScript === cell.scriptPublicKey &&
          entry?.isCoinbase !== true
        );
      });
    if (!isLive)
      throw new Error(
        "The local Kaspa node reports that this KCC20 cell is no longer spendable.",
      );
  }
  return {
    ticker: String(
      token?.ticker ?? token?.claimed_name ?? token?.name ?? "KCC20",
    ).toUpperCase(),
    decimals: Number(token?.decimals ?? token?.claimed_decimals ?? 8),
    templateHash,
    cells,
    rawBalance,
  };
}
export async function kronTransferData(
  address: string,
  covenantId: string,
  amount: number,
) {
  const owner = ownerId(address);
  if (
    !owner ||
    !/^[0-9a-f]{64}$/.test(covenantId) ||
    !Number.isSafeInteger(amount) ||
    amount <= 0
  )
    throw new Error("Invalid KRON transfer request.");
  const [balances, cellsData, token] = await Promise.all([
    get(`https://kcc20.info/v1/owners/${owner}/balances?limit=1000`),
    get(
      `https://kcc20.info/v1/owners/${owner}/cells?signing_ready=true&limit=1000`,
    ),
    get(`https://kcc20.info/v1/tokens/${covenantId}`),
  ]);
  if (verifiedKcc20Standard(token) !== "kron-native")
    throw new Error(
      "The selected token is not a template-verified KRON token.",
    );
  const balance = (
      Array.isArray(balances?.balances) ? balances.balances : []
    ).find(
      (item: any) =>
        String(item?.token_id).toLowerCase() === covenantId &&
        item?.validation_status === "template_verified" &&
        Number(item?.unresolved_cells) === 0,
    ),
    rawBalance = Number(balance?.balance);
  if (
    !Number.isSafeInteger(rawBalance) ||
    rawBalance <= 0 ||
    amount > rawBalance
  )
    throw new Error("Insufficient verified KRON balance.");
  const rows = (Array.isArray(cellsData?.cells) ? cellsData.cells : []).filter(
    (item: any) =>
      String(item?.covenant_id ?? item?.token_id).toLowerCase() ===
        covenantId &&
      item?.signing_ready !== false &&
      Number(item?.state?.amount) > 0 &&
      item?.state?.is_minter !== true,
  );
  const seen = new Set<string>(),
    cells = rows
      .map((item: any) => {
        const transactionId = String(item?.outpoint_tx_id ?? "").toLowerCase(),
          index = Number(item?.outpoint_index),
          value = Number(item?.value),
          tokenAmount = Number(item?.state?.amount),
          redeemScript = String(item?.redeem_script ?? "").toLowerCase(),
          scriptPublicKey = normalizeKcc20Script(item?.script_public_key);
        const key = `${transactionId}:${index}`;
        if (
          !/^[0-9a-f]{64}$/.test(transactionId) ||
          !Number.isSafeInteger(index) ||
          index < 0 ||
          !Number.isSafeInteger(value) ||
          value <= 0 ||
          !Number.isSafeInteger(tokenAmount) ||
          tokenAmount <= 0 ||
          !/^[0-9a-f]+$/.test(redeemScript) ||
          !/^[0-9a-f]+$/.test(scriptPublicKey) ||
          seen.has(key)
        )
          throw new Error("Invalid or duplicate KRON signing cell.");
        seen.add(key);
        return {
          transactionId,
          index,
          value,
          tokenAmount,
          redeemScript,
          scriptPublicKey,
        };
      })
      .sort((a: any, b: any) => b.tokenAmount - a.tokenAmount);
  const selected: any[] = [];
  let selectedAmount = 0;
  for (const cell of cells) {
    selected.push(cell);
    selectedAmount += cell.tokenAmount;
    if (selectedAmount >= amount) break;
    if (selected.length === 4) break;
  }
  if (selectedAmount < amount)
    throw new Error(
      "KRON balance needs more than four token cells. Consolidate it in KRON first.",
    );
  return {
    ticker: String(token?.ticker ?? token?.name ?? "KRON").toUpperCase(),
    decimals: Number(token?.decimals ?? 0),
    rawBalance,
    standard: "kron-native",
    templateHash: String(
      token?.template_hash ?? token?.kcc1_template_hash ?? "",
    ).toLowerCase(),
    cells: selected,
  };
}
export async function kcc20History(address: string) {
  const owner = ownerId(address);
  if (!owner) return [];
  const [status, result] = await Promise.all([
    get("https://kcc20.info/v1/status"),
    get(`https://kcc20.info/v1/owners/${owner}/history?limit=250`),
  ]);
  const tipDaa = Number(status?.max_daa ?? 0),
    tipAt = Number(status?.tip_at_ms ?? status?.updated_at_ms ?? Date.now());
  const rows = Array.isArray(result?.history) ? result.history : [];
  const selected = new Map<string, any>();
  for (const item of rows) {
    const tx = String(item?.tx_id ?? "").toLowerCase(),
      tokenId = String(item?.token_id ?? item?.covenant_id ?? "").toLowerCase(),
      delta = String(item?.balance_delta ?? "");
    if (
      !/^[0-9a-f]{64}$/.test(tx) ||
      !/^[0-9a-f]{64}$/.test(tokenId) ||
      !/^-[0-9]+$|^[0-9]+$/.test(delta) ||
      delta === "0"
    )
      continue;
    const key = `${tx}:${tokenId}`,
      previous = selected.get(key);
    if (
      !previous ||
      (item?.source === "node" && previous?.source !== "node") ||
      (item?.kind === "balance-change" && previous?.kind !== "balance-change")
    )
      selected.set(key, item);
  }
  const tokenIds = [
    ...new Set(
      [...selected.values()].map((item) =>
        String(item.token_id ?? item.covenant_id).toLowerCase(),
      ),
    ),
  ];
  const metadata = new Map<string, any>();
  await Promise.all(
    tokenIds.map(async (id) => {
      try {
        metadata.set(id, await get(`https://kcc20.info/v1/tokens/${id}`));
      } catch {
        metadata.set(id, {});
      }
    }),
  );
  return [...selected.values()].map((item) => {
    const tokenId = String(item.token_id ?? item.covenant_id).toLowerCase(),
      token = metadata.get(tokenId) ?? {},
      decimals = Number(token?.decimals ?? token?.claimed_decimals ?? 8),
      raw = BigInt(String(item.balance_delta)),
      incoming = raw > 0n,
      absolute = (raw < 0n ? -raw : raw).toString().padStart(decimals + 1, "0"),
      whole = decimals ? absolute.slice(0, -decimals) : absolute,
      fraction = decimals ? absolute.slice(-decimals).replace(/0+$/g, "") : "",
      daa = Number(item?.daa ?? item?.accepting_daa ?? 0),
      blockTime = tipDaa >= daa && tipAt > 0 ? tipAt - (tipDaa - daa) * 100 : 0;
    return {
      transactionId: String(item.tx_id).toLowerCase(),
      blockTime,
      isAccepted: true,
      incoming,
      assetKind: "KCC20",
      assetSymbol: String(
        token?.ticker ?? token?.claimed_name ?? token?.name ?? "KCC20",
      ).toUpperCase(),
      displayAmount: fraction ? `${whole}.${fraction}` : whole,
      tokenId,
      covenantId: tokenId,
      counterparty: "",
      from: incoming ? [] : [{ address, ownerId: owner }],
      to: incoming ? [{ address, ownerId: owner }] : [],
      feeSompi: null,
      totalInputSompi: null,
      totalOutputSompi: null,
      inputCount: null,
      outputCount: null,
      mass: null,
      blockDaaScore: daa,
      type: String(item?.kind ?? "transfer"),
    };
  });
}
export function parseKcc20BroadcastId(value: any, expectedId: string) {
  const id = String(
    value?.txId ?? value?.transactionId ?? value?.transaction_id ?? "",
  ).toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(id))
    throw new Error("KCC20 broadcaster returned no valid transaction ID.");
  if (id !== expectedId.toLowerCase())
    throw new Error("KCC20 broadcaster returned a mismatching transaction ID.");
  return id;
}
export async function broadcastKcc20(wrpcJson: string, expectedId: string) {
  const response = await fetch(
    "https://gothdag.kaslab.space/api/covenant-broadcast",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({ signedTxJson: wrpcJson }),
    },
  );
  const value = await response.json().catch(() => ({}));
  if (!response.ok)
    throw new Error(
      `KCC20 broadcast rejected (${response.status}): ${String(value?.error ?? "unknown broadcaster error")}`,
    );
  return parseKcc20BroadcastId(value, expectedId);
}
async function loadTokenAssets(address: string) {
  try {
    return await get(
      `https://kaspatoken.kaslab.space/api/wallet/krc20/${encodeURIComponent(address)}`,
    );
  } catch {
    const [tokens, domains, krc721] = await Promise.all([
      loadKasplexTokens(address).catch(() => []),
      loadKnsDomains(address).catch(() => []),
      loadKrc721Collections(address).catch(() => []),
    ]);
    return {
      data: {
        address,
        tokens,
        domains,
        krc721_tokens: krc721,
        transactions: [],
      },
      source_mode: "DIRECT_FALLBACK",
    };
  }
}
async function loadKasplexTokens(address: string) {
  const values: any[] = [];
  let next = "";
  for (let page = 0; page < 20; page++) {
    const value = await get(
      `https://api.kasplex.org/v1/krc20/address/${encodeURIComponent(address)}/tokenlist${next ? `?next=${encodeURIComponent(next)}` : ""}`,
    );
    const rows = Array.isArray(value?.result)
      ? value.result
      : Array.isArray(value?.data)
        ? value.data
        : [];
    for (const item of rows) {
      const symbol = String(
        item?.tick ?? item?.ticker ?? item?.symbol ?? "",
      ).toUpperCase();
      const decimals = Number(item?.dec ?? item?.decimals ?? 8);
      const raw = String(item?.balance ?? item?.amount ?? "0");
      if (
        /^[A-Z0-9_-]{1,32}$/.test(symbol) &&
        Number.isInteger(decimals) &&
        decimals >= 0 &&
        decimals <= 18 &&
        /^\d+$/.test(raw) &&
        BigInt(raw) > 0n
      )
        values.push({
          token_id: `krc20-${symbol.toLowerCase()}`,
          symbol,
          decimals,
          raw_balance: raw,
          balance: Number(raw) / 10 ** decimals,
        });
    }
    next = String(value?.next ?? value?.next_cursor ?? "");
    if (!next || !rows.length) break;
  }
  return values;
}
async function loadKnsDomains(address: string) {
  const values: any[] = [];
  for (let page = 1; page <= 100; page++) {
    const query = new URLSearchParams({
      owner: address,
      page: String(page),
      pageSize: "100",
      type: "domain",
    });
    const value = await get(
      `https://api.knsdomains.org/mainnet/api/v1/assets?${query}`,
    );
    const rows = Array.isArray(value?.data?.assets) ? value.data.assets : [];
    for (const item of rows) {
      const name = String(
        item?.asset ?? item?.domain ?? item?.name ?? "",
      ).toLowerCase();
      const assetId = String(
        item?.assetId ?? item?.asset_id ?? "",
      ).toLowerCase();
      if (
        /^[a-z0-9][a-z0-9.-]*\.kas$/.test(name) &&
        /^[0-9a-f]{64}i0$/.test(assetId)
      )
        values.push({ name, asset_id: assetId, status: item?.status });
    }
    const total = Number(value?.data?.pagination?.totalPages ?? 0);
    if (!rows.length || (total > 0 ? page >= total : rows.length < 100)) break;
  }
  return values;
}
async function loadKrc721Collections(address: string) {
  const grouped = new Map<string, number>();
  let offset = "";
  for (let page = 0; page < 100; page++) {
    const query = new URLSearchParams({
      limit: "500",
      direction: "forward",
      ...(offset ? { offset } : {}),
    });
    const value = await get(
      `https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet/address/${encodeURIComponent(address)}?${query}`,
    );
    const rows = Array.isArray(value?.result) ? value.result : [];
    for (const item of rows) {
      const symbol = String(item?.tick ?? "").toUpperCase();
      if (/^[A-Z0-9_-]{1,32}$/.test(symbol))
        grouped.set(symbol, (grouped.get(symbol) ?? 0) + 1);
    }
    const next = String(value?.next ?? "");
    if (!next || !rows.length) break;
    offset = next;
  }
  return [...grouped].map(([symbol, balance]) => ({
    token_id: `krc721-${symbol.toLowerCase()}`,
    symbol,
    name: symbol,
    balance,
  }));
}
export async function walletCoreSnapshot(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const endpoint = network === "mainnet" ? MAINNET : TN10;
  const [balance, utxos] = await Promise.all([
    get(`${endpoint}/addresses/${encodeURIComponent(address)}/balance`),
    get(`${endpoint}/addresses/${encodeURIComponent(address)}/utxos`),
  ]);
  const sompi = Number(balance?.balance ?? 0);
  if (!Number.isSafeInteger(sompi) || sompi < 0)
    throw new Error("Node returned an invalid balance.");
  if (!Array.isArray(utxos)) throw new Error("Node returned invalid UTXOs.");
  return {
    balanceSompi: sompi,
    balanceKas: sompi / 100_000_000,
    utxoCount: utxos.length,
    utxos,
  };
}
export async function walletBalance(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const value = await get(
    `${network === "mainnet" ? MAINNET : TN10}/addresses/${encodeURIComponent(address)}/balance`,
  );
  const sompi = Number(value?.balance ?? 0);
  if (!Number.isSafeInteger(sompi) || sompi < 0)
    throw new Error("Node returned an invalid balance.");
  return { balanceSompi: sompi, balanceKas: sompi / 100_000_000 };
}
const assetCache = new Map<string, { at: number; value: any }>();
const inscriptionCache = new Map<string, { at: number; value: any }>();
export async function inscriptionAssets(address: string) {
  const cached = inscriptionCache.get(address);
  if (cached) return cached.value;
  const walletCached = assetCache.get(address);
  if (walletCached) {
    const value = {
      tokens: walletCached.value.tokens,
      domains: walletCached.value.domains,
      krc721: walletCached.value.krc721,
      transactions: walletCached.value.transactions,
    };
    inscriptionCache.set(address, { at: Date.now(), value });
    return value;
  }
  const raw = await loadTokenAssets(address);
  const data = raw?.data && typeof raw.data === "object" ? raw.data : {};
  const value = {
    tokens: Array.isArray(data.tokens)
      ? data.tokens.map((item: any) => ({
          ...item,
          symbol: String(item?.symbol ?? "").toUpperCase(),
        }))
      : [],
    domains: Array.isArray(data.domains) ? data.domains : [],
    krc721: Array.isArray(data.krc721_tokens)
      ? data.krc721_tokens.map((item: any) => ({
          ...item,
          symbol: String(item?.symbol ?? "").toUpperCase(),
        }))
      : [],
    transactions: Array.isArray(data.transactions) ? data.transactions : [],
  };
  inscriptionCache.set(address, { at: Date.now(), value });
  return value;
}
export async function walletAssets(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  if (network !== "mainnet")
    return { tokens: [], domains: [], krc721: [], kcc20: [], transactions: [] };
  const cached = assetCache.get(address);
  if (cached && Date.now() - cached.at < 30_000) return cached.value;
  const [rawAssets, kcc20] = await Promise.all([
    loadTokenAssets(address).catch(() => null),
    loadKcc20Assets(address).catch(() => []),
  ]);
  const data =
    rawAssets?.data && typeof rawAssets.data === "object" ? rawAssets.data : {};
  const value = {
    tokens: Array.isArray(data.tokens)
      ? data.tokens
          .filter(
            (item: any) =>
              typeof item?.symbol === "string" &&
              typeof item?.raw_balance === "string" &&
              Number.isInteger(item?.decimals) &&
              item.decimals >= 0 &&
              item.decimals <= 18,
          )
          .map((item: any) => ({
            ...item,
            symbol: String(item.symbol).toUpperCase(),
          }))
      : [],
    domains: Array.isArray(data.domains)
      ? data.domains.filter(
          (item: any) =>
            typeof item?.name === "string" &&
            /^[a-z0-9][a-z0-9.-]*\.kas$/.test(item.name),
        )
      : [],
    krc721: Array.isArray(data.krc721_tokens)
      ? data.krc721_tokens
          .filter((item: any) => typeof item?.symbol === "string")
          .map((item: any) => ({
            ...item,
            symbol: String(item.symbol).toUpperCase(),
          }))
      : [],
    kcc20: kcc20.map((item: any) => ({
      ...item,
      symbol: String(item.symbol).toUpperCase(),
    })),
    transactions: Array.isArray(data.transactions) ? data.transactions : [],
  };
  assetCache.set(address, { at: Date.now(), value });
  inscriptionCache.set(address, {
    at: Date.now(),
    value: {
      tokens: value.tokens,
      domains: value.domains,
      krc721: value.krc721,
      transactions: value.transactions,
    },
  });
  return value;
}
export async function walletSnapshot(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const [core, assets] = await Promise.all([
    walletCoreSnapshot(address, network),
    walletAssets(address, network),
  ]);
  return { ...core, assets, transactions: assets.transactions };
}
export async function networkDiagnostics(
  address: string,
  network: "mainnet" | "testnet-10",
) {
  const endpoint = network === "mainnet" ? MAINNET : TN10;
  const checks = [
    {
      name: "Kaspa node",
      url: `${endpoint}/addresses/${encodeURIComponent(address)}/balance`,
    },
    ...(network === "mainnet"
      ? [
          {
            name: "KRC-20 / KNS / KRC-721",
            url: `https://kaspatoken.kaslab.space/api/wallet/krc20/${encodeURIComponent(address)}`,
          },
          {
            name: "KRC-20 fallback",
            url: `https://api.kasplex.org/v1/krc20/address/${encodeURIComponent(address)}/tokenlist`,
          },
          {
            name: "KNS fallback",
            url: `https://api.knsdomains.org/mainnet/api/v1/assets?owner=${encodeURIComponent(address)}&page=1&pageSize=1&type=domain`,
          },
          { name: "KCC20 indexer", url: "https://kcc20.info/v1/status" },
        ]
      : []),
  ];
  return Promise.all(
    checks.map(async (check) => {
      const started = performance.now();
      try {
        await get(check.url);
        return {
          ...check,
          ok: true,
          detail: "Online and returned valid JSON",
          elapsedMs: Math.round(performance.now() - started),
        };
      } catch (error) {
        return {
          ...check,
          ok: false,
          detail: (error as Error).message,
          elapsedMs: Math.round(performance.now() - started),
        };
      }
    }),
  );
}
