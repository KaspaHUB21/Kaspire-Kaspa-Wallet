import type { Kcc20DexTrade, Kcc20Event, Kcc20OwnerChange } from "../types/token";

export function kcc20EventAmount(event: Pick<Kcc20Event, "amount">, changes: Kcc20OwnerChange[]): number | null {
  if(event.amount !== null)return event.amount;
  if(!changes.length)return null;
  const sum = (direction: "from" | "to") => changes.filter(c=>c.direction===direction&&Number.isFinite(c.amount)&&c.amount>=0).reduce((n,c)=>n+c.amount,0);
  return Math.max(sum("from"),sum("to"));
}

export type Kcc20TransactionLabel = "Transfer" | "Send" | "Receive" | "Buy" | "Sell" | "Swap" | "Mint" | "Burn" | "Merge" | "Split" | "Deploy" | "Transaction";

const operationLabels: Record<string, Kcc20TransactionLabel> = {
  transfer: "Transfer", send: "Send", receive: "Receive",
  observed_transfer: "Transfer", observed_mint: "Mint", observed_burn: "Burn",
  buy: "Buy", sell: "Sell", swap: "Swap",
  mint: "Mint", issuance: "Mint", burn: "Burn",
  merge: "Merge", split: "Split", genesis: "Deploy", deploy: "Deploy", deployment: "Deploy"
};

/** Match actual executions by transaction ID, never by amount, time or owner type. */
export function kcc20TradeLabels(trades: Pick<Kcc20DexTrade, "txid" | "side">[]): Map<string, Kcc20TransactionLabel> {
  const labels = new Map<string, Kcc20TransactionLabel>();
  for (const trade of trades) {
    const txid = trade.txid.trim().toLowerCase();
    const side = trade.side.trim().toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(txid) || (side !== "buy" && side !== "sell")) continue;
    const label = side === "buy" ? "Buy" : "Sell";
    const previous = labels.get(txid);
    labels.set(txid, previous && previous !== label ? "Swap" : label);
  }
  return labels;
}

export function kcc20TransactionLabel(
  event: Pick<Kcc20Event, "txid" | "event_kind" | "token_kind">,
  tradeLabels: ReadonlyMap<string, Kcc20TransactionLabel>
): Kcc20TransactionLabel {
  const trade = tradeLabels.get(event.txid.trim().toLowerCase());
  if (trade) return trade;
  // event_kind is the on-chain operation. token_kind may still contain a
  // technical flow classification in older cached snapshots.
  for (const kind of [event.event_kind, event.token_kind]) {
    const label = operationLabels[kind.trim().toLowerCase()];
    if (typeof label === "string") return label;
  }
  return "Transaction";
}

