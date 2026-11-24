import { ArrowRight, BarChart3 } from "./icons";
import { Link } from "react-router-dom";
import type { Token } from "../types/token";
import { FavoriteButton } from "./FavoriteButton";
import { StatusBadge } from "./StatusBadge";
import { TokenLogo } from "./TokenLogo";
import { formatAgeSince, formatCurrency, formatKas, formatKasVolume, formatPlainPercent } from "../utils/format";
import { TokenVolume } from "./TokenVolume";
import { usePortfolioStore } from "../services/portfolio";
import {CovenantIdentity} from './CovenantIdentity';

interface TokenCardProps {
  token: Token;
  rank?: number;
  showMarketData?: boolean;
}

export function TokenCard({ token, rank, showMarketData = true }: TokenCardProps) {
  const { isFavorite } = usePortfolioStore();
  const favorite = isFavorite(token.id);
  const isKrc721 = token.layer === "KRC721";
  const flaggedDagas = isDagasWarningToken(token);

  return (
    <article className={["group kaspa-panel min-w-0 overflow-hidden rounded-md p-4 transition hover:border-kaspa-primary/80 hover:shadow-kaspa", favorite ? "border-kaspa-primary/80 shadow-kaspa" : ""].join(" ")}>
      <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <Link to={tokenDetailPath(token)} className="focus-ring flex min-w-0 items-center gap-3 rounded-sm">
          {rank !== undefined ? <span className="flex h-8 min-w-8 shrink-0 items-center justify-center rounded-sm border border-kaspa-border bg-kaspa-background px-2 text-xs font-bold text-kaspa-muted">#{rank}</span> : null}
          <TokenLogo src={token.image_url} symbol={token.symbol} />
          <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-1.5">
              <div className="truncate text-base font-bold text-kaspa-text">{token.symbol}</div>
              {flaggedDagas ? <span className="shrink-0 text-lg font-black leading-none text-red-500" title="100% dev minted airdrop token. Metrics have been reported to be not real.">*</span> : null}
            </div>
            {token.deployed_at || token.mint_percent !== undefined && token.mint_percent !== null ? (
              <div className="mt-1 flex flex-wrap gap-2 text-[11px] font-semibold text-kaspa-muted">
                {token.deployed_at ? <span>Age {formatAgeSince(token.deployed_at)}</span> : null}
                {token.mint_percent !== undefined && token.mint_percent !== null ? <span>Mint {formatPlainPercent(token.mint_percent)}</span> : null}
              </div>
            ) : null}
          </div>
        </Link>
        <div className="flex max-w-full shrink-0 flex-wrap items-center gap-2 sm:justify-end">
          <FavoriteButton tokenId={token.id} compact />
          {!isKrc721 ? <StatusBadge verified={token.verified} reason={token.verification_reason} /> : null}
        </div>
      </div>

      {token.layer==='KCC20'?<CovenantIdentity value={token.contract_address||/^kcc20-([a-f0-9]{64})$/i.exec(token.id)?.[1]}/>:null}

      {showMarketData ? (
        <div className="mt-5 grid grid-cols-2 gap-3 text-sm">
          <div>
            <div className="text-xs font-semibold text-kaspa-muted">{isKrc721 ? "Floor" : "Price"}</div>
            <div className="mt-1 font-bold text-kaspa-primary">{formatKas(token.price_kas)}</div>
            {!isKrc721 ? <div className="text-xs text-kaspa-muted">{formatCurrency(token.price_usd)}</div> : null}
          </div>
          <div>
            <div className="text-xs font-semibold text-kaspa-muted">{isKrc721 ? "All Time Volume" : "Market Cap"}</div>
            <div className="mt-1 font-bold text-kaspa-text">{isKrc721 ? formatKasVolume(token.all_time_volume_kas) : token.unusual_market_cap ? "Unusual market cap detected" : formatCurrency(token.market_cap_usd)}</div>
            {token.unusual_market_cap ? <div className="text-xs font-semibold text-kaspa-primary">* ({formatCurrency(token.market_cap_usd)})</div> : null}
            {!isKrc721 ? <div className="text-xs text-kaspa-muted">{formatKas(token.market_cap_kas)}</div> : null}
          </div>
        </div>
      ) : (
        <div className="mt-5 rounded-sm border border-kaspa-border bg-kaspa-background/50 px-3 py-3 text-sm">
          <div className="text-xs font-semibold text-kaspa-muted">Source</div>
          <div className="mt-1 truncate font-semibold text-kaspa-text" title={token.source || token.contract_address}>{token.source || "L2 DEX factory discovery"}</div>
          {token.contract_address ? <div className="mt-1 truncate font-mono text-xs text-kaspa-muted" title={token.contract_address}>{token.contract_address}</div> : null}
        </div>
      )}

      {showMarketData ? (
        <div className="mt-5 grid grid-cols-3 gap-2 border-t border-kaspa-border pt-4 text-xs">
          <div><div className="text-kaspa-muted">24h</div><div className="font-bold text-kaspa-text">{isKrc721 ? formatKasVolume(token.volume_24h_kas) : formatCurrency(token.volume_24h_usd)}</div></div>
          <div><div className="text-kaspa-muted">7d</div><div className="font-bold text-kaspa-text"><TokenVolume token={token} window="7d" /></div></div>
          <div><div className="text-kaspa-muted">30d</div><div className="font-bold text-kaspa-text"><TokenVolume token={token} window="30d" /></div></div>
        </div>
      ) : null}

      <div className="mt-4 flex items-center justify-end text-xs text-kaspa-muted">
        <Link to={tokenDetailPath(token)} className="focus-ring inline-flex items-center gap-1 rounded-sm text-kaspa-primary">
          <BarChart3 className="h-3.5 w-3.5" aria-hidden="true" /><ArrowRight className="h-3.5 w-3.5 transition group-hover:translate-x-0.5" aria-hidden="true" />
        </Link>
      </div>
    </article>
  );
}

function isDagasWarningToken(token: Token) {
  return token.layer === "KRC20" && token.symbol.trim().toUpperCase() === "DAGAS";
}

function tokenDetailPath(token: Token) {
  return token.layer === "KCC20" && token.contract_address
    ? "/kcc20/" + encodeURIComponent(token.contract_address)
    : "/token/" + encodeURIComponent(token.id);
}

