import type {Token} from "../types/token";

export function compareKcc20Tokens(a: Token, b: Token): number {
  return Number(b.verified) - Number(a.verified)
    || (b.market_cap_usd || 0) - (a.market_cap_usd || 0)
    || (b.volume_24h_usd || 0) - (a.volume_24h_usd || 0)
    || a.symbol.localeCompare(b.symbol);
}

