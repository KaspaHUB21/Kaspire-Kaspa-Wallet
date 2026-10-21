const API_ROOT = "https://kaspire.kaslab.space/api/kasparocket/pro-api";
const CATALOGUE_ROOT = "https://kaspire.kaslab.space/api/kasparocket";
export type RocketNetwork = 'mainnet' | 'testnet-10';
export function requireRocketNetwork(network: string): asserts network is RocketNetwork {
  if (network !== 'mainnet') throw Error('KaspaRocket currently serves Kaspa Mainnet. Switch to Layer 1 to trade; TN10 is not available from the provider.');
}
function requireRocketAddress(address: string) {
  if (!address.startsWith('kaspa:')) throw Error('The wallet address does not match KaspaRocket Mainnet.');
}
export class RocketConflict extends Error {}
export class RocketQuoteExpired extends Error {
  constructor() { super('The pool changed before this swap executed. The obsolete swap was archived. Refresh the quote to try again.'); }
}
let protocolCheck: { at: number; task: Promise<void> } | undefined;
export async function verifyRocketNetwork(network: string = 'mainnet') {
  requireRocketNetwork(network);
  if (!protocolCheck || Date.now() - protocolCheck.at > 30_000) {
    const task = request('GET', `${API_ROOT}/protocol`).then(value => {
      if (value?.network !== network || Number(value?.token?.decimals) !== ROCKET_TOKEN_DECIMALS)
        throw Error('KaspaRocket is not serving the expected network or token configuration. Nothing was signed.');
    }).catch(error => { protocolCheck = undefined; throw error; });
    protocolCheck = {at: Date.now(), task};
  }
  return protocolCheck.task;
}
export const ROCKET_TOKEN_DECIMALS = 3;

export interface RocketToken {
  tokenId: string;
  ticker: string;
  name: string;
  image: string;
  description: string;
  priceKas: number | null;
  marketCapKas: number | null;
  volume24hKas: number | null;
  change24h: number | null;
  poolValueKas: number | null;
  phase: string | null;
}

async function request(
  method: "GET" | "POST",
  url: string,
  body?: Record<string, unknown>,
  retry = true,
  signal?: AbortSignal,
): Promise<any> {
  let last: unknown;
  for (let attempt = 0; attempt < (retry ? 2 : 1); attempt++) {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(
        () => controller.abort(),
        method === "GET" ? 25_000 : 40_000,
      );
      const response = await fetch(url, {
        method,
        signal: signal ? AbortSignal.any([controller.signal, signal]) : controller.signal,
        redirect: 'error',
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }).finally(() => clearTimeout(timeout));
      const value = response.status === 204 ? {} : await response.json();
      if (!response.ok) {
        if (response.status === 409) throw new RocketConflict(String(
          value?.error?.message ?? value?.message ?? value?.detail ?? value?.error ?? 'The live pool or wallet state changed.'));
        throw new Error(
          `KaspaRocket: ${value?.message ?? value?.detail ?? value?.error ?? response.status}`,
        );
      }
      return value;
    } catch (error) {
      last = error;
      if (error instanceof RocketConflict || signal?.aborted) throw error;
      if (!retry || attempt === 1) throw error;
      await new Promise((resolve) => setTimeout(resolve, 350));
    }
  }

  throw last instanceof Error ? last : new Error("KaspaRocket request failed.");
}

export async function rocketWalletAssets(address: string): Promise<any[]> {
  requireRocketAddress(address);
  const value = await request(
    "GET",
    `${API_ROOT}/tokens/${encodeURIComponent(address)}`,
  );
  const rows = Array.isArray(value?.tokens) ? value.tokens : [];
  return rows
    .map((row: any) => {
      const covenantId = String(row?.kcc20_covenant_id ?? "").toLowerCase();
      const rawBalance = String(row?.balance_tokens ?? "0");
      if (
        !/^[0-9a-f]{64}$/.test(covenantId) ||
        !/^\d+$/.test(rawBalance) ||
        BigInt(rawBalance) <= 0n
      )
        return null;
      const priceSompi = numeric(row?.price_sompi);
      return {
        symbol: String(row?.ticker ?? "KCC20").toUpperCase(),
        rawBalance,
        decimals: ROCKET_TOKEN_DECIMALS,
        covenantId,
        tokenId: covenantId,
        image_url: String(row?.image_url ?? ""),
        priceKas: priceSompi == null ? null : priceSompi * 10 ** ROCKET_TOKEN_DECIMALS / 100_000_000,
        standard: "kasparocket-kcc20",
        validationStatus: "kasparocket-indexed",
        discoveryComplete: false,
      };
    })
    .filter(Boolean)
    .sort(
      (left: any, right: any) =>
        left.symbol.localeCompare(right.symbol, "en") ||
        left.covenantId.localeCompare(right.covenantId),
    );
}

function numeric(value: unknown): number | null {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export async function rocketTokens(network: string = 'mainnet'): Promise<RocketToken[]> {
  await verifyRocketNetwork(network);
  const [catalogue, analytics] = await Promise.all([
    request("GET", `${CATALOGUE_ROOT}/api/tokens`),
    request("GET", `${CATALOGUE_ROOT}/api/analytics?page=1&limit=500`),
  ]);
  const stats = new Map(
    (Array.isArray(analytics?.tokens) ? analytics.tokens : []).map((row: any) => [
      String(row.token_id),
      row,
    ]),
  );
  const tokens = (Array.isArray(catalogue) ? catalogue : []).map((row: any) => {
    const tokenId = String(row.token_id ?? "");
    const stat: any = stats.get(tokenId);
    return {
      tokenId,
      ticker: String(row.ticker ?? stat?.ticker ?? "TOKEN").toUpperCase(),
      name: String(row.token_name ?? stat?.name ?? "KaspaRocket token"),
      image: String(row.image_url ?? stat?.image ?? ""),
      description: String(row.description ?? ""),
      priceKas: numeric(stat?.price),
      marketCapKas: numeric(stat?.marketCap),
      volume24hKas: numeric(stat?.volume24h),
      change24h: numeric(stat?.change24h),
      poolValueKas: numeric(stat?.pool_value_kas),
      phase: stat?.phase == null ? null : String(stat.phase),
    } satisfies RocketToken;
  });
  return tokens.sort(
    (left, right) =>
      (right.poolValueKas ?? -1) - (left.poolValueKas ?? -1) ||
      left.ticker.localeCompare(right.ticker),
  );
}

export async function rocketPool(tokenId: string): Promise<string> {
  const rows = await request(
    "GET",
    `${CATALOGUE_ROOT}/api/covenants/by-token/${encodeURIComponent(tokenId)}`,
  );
  const match = (Array.isArray(rows) ? rows : []).find(
    (row: any) =>
      row?.utxo_type === "amm" && String(row?.lp_amm_covenant_id ?? ""),
  );
  if (!match) throw new Error("This token has no active KaspaRocket pool.");
  return String(match.lp_amm_covenant_id);
}

export function rocketHolding(address: string, tokenId: string) {
  requireRocketAddress(address);
  return request(
    "GET",
    `${API_ROOT}/tokens/${encodeURIComponent(address)}/${encodeURIComponent(tokenId)}`,
  );
}

export function rocketHoldingRaw(holding: any): bigint {
  for (const key of ["balance_tokens", "raw_balance", "balance"]) {
    const value = String(holding?.[key] ?? "");
    if (/^\d+$/.test(value)) return BigInt(value);
  }
  return 0n;
}

export function formatRocketTokenRaw(
  value: bigint | string,
  decimals = ROCKET_TOKEN_DECIMALS,
): string {
  const raw = typeof value === "bigint" ? value : BigInt(value);
  const scale = 10n ** BigInt(decimals);
  const whole = raw / scale;
  const fraction = (raw % scale)
    .toString()
    .padStart(decimals, "0")
    .replace(/0+$/, "");
  return `${whole}${fraction ? `.${fraction}` : ""}`;
}

export function validateRocketFunds(
  side: "buy" | "sell",
  rawAmount: string,
  holding: any,
  balanceSompi: number | string,
  quote?: any,
  ticker = "token",
): void {
  const requested = BigInt(rawAmount);
  if (side === "sell") {
    const available = rocketHoldingRaw(holding);
    if (requested > available)
      throw new Error(
        `Insufficient ${ticker.toUpperCase()}. Available: ${formatRocketTokenRaw(available)} ${ticker.toUpperCase()}.`,
      );
    return;
  }
  const quoted = String(quote?.net_kas_sompi ?? "");
  const quotedMagnitude = /^-?\d+$/.test(quoted)
    ? (BigInt(quoted) < 0n ? -BigInt(quoted) : BigInt(quoted))
    : requested;
  const required = quotedMagnitude > requested ? quotedMagnitude : requested;
  if (required > BigInt(balanceSompi))
    throw new Error(
      "Insufficient KAS. Reduce the trade amount to leave room for DEX and network fees.",
    );
}

export function rocketTokenAmountDisplay(value: any): string {
  const display =
    value?.amountTokensDisplay ?? value?.amount_tokens_display;
  if (display !== undefined && display !== null && String(display).trim())
    return String(display).trim();
  const raw = value?.amountTokens ?? value?.amount_tokens;
  return raw === undefined || raw === null
    ? "\u2014"
    : formatRocketTokenRaw(String(raw));
}

export async function rocketQuote(
  tokenId: string,
  poolId: string,
  side: "buy" | "sell",
  rawAmount: string,
) {
  const quote = await request("POST", `${API_ROOT}/pool/quote`, {
    lp_covenant_id: poolId,
    kcc20_covenant_id: tokenId,
    direction: side,
    ...(side === "buy"
      ? { kas_budget_sompi: rawAmount }
      : { amount_tokens: rawAmount }),
  });
  return {
    ...quote,
    amountTokensDisplay: rocketTokenAmountDisplay(quote),
  };
}

function tradeBody(
  address: string,
  tokenId: string,
  poolId: string,
  side: "buy" | "sell",
  rawAmount: string,
  expected?: unknown,
) {
  return {
    address,
    lp_covenant_id: poolId,
    kcc20_covenant_id: tokenId,
    side,
    kind: "market",
    ...(side === "buy"
      ? { budget_sompi: rawAmount }
      : { tokens: rawAmount }),
    max_fills: 3,
    attendu: expected ?? null,
    apres_tx: null,
  };
}

export async function rocketPlan(
  address: string,
  tokenId: string,
  poolId: string,
  side: "buy" | "sell",
  rawAmount: string,
) {
  requireRocketAddress(address);
  await verifyRocketNetwork();
  const route = await request(
    "POST",
    `${API_ROOT}/route`,
    tradeBody(address, tokenId, poolId, side, rawAmount),
  );
  const plan = await request(
    "POST",
    `${API_ROOT}/plan/trade`,
    tradeBody(address, tokenId, poolId, side, rawAmount, route?.attendu),
    false,
  );
  const summary = plan?.summary;
  if (plan?.networkId !== 'mainnet' || summary?.direction !== side ||
      !/^\d+$/.test(String(side === 'buy' ? summary?.kasFlowSompi : summary?.amountTokens)) ||
      BigInt(side === 'buy' ? summary.kasFlowSompi : summary.amountTokens) > BigInt(rawAmount))
    throw Error('KaspaRocket plan differs from the requested Mainnet trade. Nothing was signed.');
  return {
    ...plan,
    ...(summary && typeof summary === "object"
      ? {
          summary: {
            ...summary,
            amountTokensDisplay: rocketTokenAmountDisplay(summary),
          },
        }
      : {}),
    route,
  };
}

function encodeScript(raw: any): string {
  if (!raw || !Number.isInteger(Number(raw.version)))
    throw new Error("KaspaRocket returned an invalid script.");
  return Number(raw.version).toString(16).padStart(4, "0") + String(raw.script);
}

function normalizeTransaction(tx: any) {
  const providerTransactionId =
    tx?.id == null ? null : String(tx.id).toLowerCase();
  if (
    providerTransactionId !== null &&
    !/^[0-9a-f]{64}$/.test(providerTransactionId)
  )
    throw new Error("KaspaRocket returned an invalid transaction ID.");
  const normalized: any = {
    ...tx,
    inputs: (tx.inputs ?? []).map((item: any) => ({
      transactionId: item.previousOutpoint?.transactionId,
      index: item.previousOutpoint?.index,
      sequence: item.sequence,
      computeBudget: item.computeBudget,
      signatureScript: item.signatureScript ?? "",
      utxo: {
        ...item.utxo,
        scriptPublicKey: encodeScript(item.utxo?.scriptPublicKey),
      },
    })),
    outputs: (tx.outputs ?? []).map((item: any) => ({
      ...item,
      scriptPublicKey: encodeScript(item.scriptPublicKey),
    })),
    storageMass: tx.storageMass ?? tx.mass ?? 0,
  };
  delete normalized.id;
  if (providerTransactionId)
    normalized.providerTransactionId = providerTransactionId;
  return normalized;
}

export function rocketSigningRequest(
  address: string,
  token: RocketToken,
  poolId: string,
  side: "buy" | "sell",
  summary: any,
  planned: any,
) {
  requireRocketAddress(address);
  const signInputs: any[] = [];
  const scripts: any[] = [];
  for (const item of planned.signingInstructions ?? []) {
    const index = Number(item.inputIndex);
    if (item.kind === "p2pkh")
      signInputs.push({
        index,
        sighashType: 1,
        expectedSighash: item.sighash,
      });
    else if (item.kind === "covenant-leader")
      scripts.push({
        inputIndex: index,
        scriptHex: "",
        signType: 1,
        prebuiltSignatureScript: item.sigscript,
        signatureOffsets: item.sigOffsets,
        expectedSighash: item.sighash,
      });
    else if (item.kind !== "final")
      throw new Error(
        `Unsupported KaspaRocket signing instruction: ${item.kind}`,
      );
  }
  return {
    sender: address,
    profile: "kasparocket-mainnet-v1",
    tokenId: token.tokenId,
    lpCovenantId: poolId,
    ticker: token.ticker,
    side,
    tradeSummary: summary,
    txJsonString: JSON.stringify(normalizeTransaction(planned.tx)),
    signInputs,
    scripts,
  };
}

export function mergeRocketTransaction(original: any, signedJson: string, transactionId?: string) {
  const signed = JSON.parse(signedJson);
  const inputs = (original.inputs ?? []).map((item: any) => ({ ...item }));
  if (inputs.length !== signed.inputs?.length)
    throw new Error("Signed transaction input count changed.");
  inputs.forEach((item: any, index: number) => {
    item.signatureScript = signed.inputs[index].signatureScript;
  });
  if (transactionId && !/^[0-9a-f]{64}$/.test(transactionId)) throw Error('Invalid locally signed transaction ID.');
  return { ...original, inputs, ...(transactionId ? {id: transactionId} : {}) };
}

export function submitRocket(
  transaction: any,
  orderRow?: Record<string, unknown>,
  signal?: AbortSignal,
) {
  return request(
    "POST",
    `${API_ROOT}/submit`,
    {
      transactions: [transaction],
      ...(orderRow ? { order_row: orderRow } : {}),
    },
    false,
    signal,
  );
}

export function rocketActivity(address: string) {
  requireRocketAddress(address);
  return request(
    "GET",
    `${CATALOGUE_ROOT}/api/activity/${encodeURIComponent(address)}?page=1&limit=100`,
  );
}

export function mergeRocketAssets(ordinary: any[], rocket: any[]) {
  const key = (row: any) => String(row.covenantId ?? row.tokenId ?? row.id ?? row.symbol).toLowerCase();
  const rows = new Map(ordinary.map(row => [key(row), row]));
  for (const row of rocket) {
    const previous = rows.get(key(row));
    if (!previous || previous.discoveryComplete !== true) rows.set(key(row), row);
  }
  return [...rows.values()].sort((a, b) => String(a.symbol).localeCompare(String(b.symbol), 'en') || key(a).localeCompare(key(b)));
}

export function rawRocketAmount(input: string, decimals: number): string {
  const value = input.trim().replace(",", ".");
  if (!/^\d+(?:\.\d+)?$/.test(value))
    throw new Error("Enter a positive decimal amount.");
  const [whole, fraction = ""] = value.split(".");
  if (fraction.length > decimals)
    throw new Error(`Enter no more than ${decimals} decimal places.`);
  const raw =
    BigInt(whole ?? "0") * 10n ** BigInt(decimals) +
    BigInt(fraction.padEnd(decimals, "0") || "0");
  if (raw <= 0n) throw new Error("Amount must be positive.");
  return raw.toString();
}
