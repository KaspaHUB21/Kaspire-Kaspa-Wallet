import { ListFilter, Search } from "../components/icons";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import type { Token, TokenLayer } from "../types/token";
import { EmptyState } from "../components/EmptyState";
import { LoadingState } from "../components/LoadingState";
import { MetricTile } from "../components/MetricTile";
import { MoverPanel } from "../components/MoverPanel";
import { TokenCard } from "../components/TokenCard";
import { TokenLogo } from "../components/TokenLogo";
import { useExplorerTokens } from "../services/tokens";
import { formatCurrency, formatInteger, formatKas, formatPlainPercent } from "../utils/format";
import { usePortfolioStore } from "../services/portfolio";
import { Link } from "react-router-dom";
import {displayableKcc20} from "../utils/kcc20Visibility";
import { compareKcc20Tokens } from "../utils/tokenRanking";

type ExplorerLayer = TokenLayer | "COMBINED";
interface ExplorerPageProps { layer: ExplorerLayer; }
type ChangeField = "price_change_7d_percent" | "price_change_24h_percent";
const pageSize = 15;
const moverMinimumVolumeUsd = 50;

function buildMovers(tokens: Token[], field: ChangeField) {
  const candidates = tokens.filter((token) => {
    const value = token[field];
    const requiredVolume = field === "price_change_24h_percent" ? token.volume_24h_usd : token.volume_7d_usd;
    return (token.verified || requiredVolume >= moverMinimumVolumeUsd) && requiredVolume > 0 && typeof value === "number" && Number.isFinite(value);
  });
  return {
    gainers: [...candidates].filter((token) => (token[field] ?? 0) > 0).sort((a, b) => (b[field] ?? 0) - (a[field] ?? 0)).slice(0, 5),
    losers: [...candidates].filter((token) => (token[field] ?? 0) < 0).sort((a, b) => (a[field] ?? 0) - (b[field] ?? 0)).slice(0, 5)
  };
}

export function ExplorerPage({ layer }: ExplorerPageProps) {
  const [query, setQuery] = useState("");
  const [searchParams] = useSearchParams();
  const [page, setPage] = useState(1);
  const navigate = useNavigate();
  const { favoriteIds } = usePortfolioStore();
  const favoritesOnly = searchParams.get("favorites") === "1";
  const tokensState = useExplorerTokens(layer);
  const rawTokens = tokensState.data?.tokens || [];
  const tokens = useMemo(() => sortExplorerTokens(rawTokens.filter(t=>t.layer!=="L2"&&(t.layer!=="KCC20"||displayableKcc20(t))).map(normalizeExplorerToken), layer), [rawTokens, layer]);
  const rankById = useMemo(() => new Map(tokens.map((token, index) => [token.id, index + 1])), [tokens]);
  const movers = useMemo(() => {
    const oneDay = buildMovers(tokens, "price_change_24h_percent");
    return { ...oneDay, field: "price_change_24h_percent" as ChangeField, label: "24h" };
  }, [tokens]);
  const mintingNow = useMemo(() => tokens
    .filter((token) => token.layer === "KRC721" && (token.mint_activity_count || 0) > 0)
    .sort((a, b) => (b.mint_activity_count || 0) - (a.mint_activity_count || 0) || (b.total_minted || 0) - (a.total_minted || 0))
    .slice(0, 3), [tokens]);
  const overview = useMemo(() => tokens.reduce((acc, token) => ({
    marketCapUsd: acc.marketCapUsd + (isUnusualMarketCap(token) ? 0 : token.market_cap_usd || 0),
    volume24hUsd: acc.volume24hUsd + token.volume_24h_usd,
    volume24hKas: acc.volume24hKas + (token.volume_24h_kas || 0),
    volume30dKas: acc.volume30dKas + (token.volume_30d_kas || 0),
    allTimeKas: acc.allTimeKas + (token.all_time_volume_kas || 0),
    volume7dUsd: acc.volume7dUsd + token.volume_7d_usd,
    verified: acc.verified + (token.verified ? 1 : 0)
  }), { marketCapUsd: 0, volume24hUsd: 0, volume24hKas: 0, volume7dUsd: 0, volume30dKas: 0, allTimeKas: 0, verified: 0 }), [tokens]);
  const hasMarketData = useMemo(() => tokens.some((token) => Boolean(
    token.price_kas ||
    token.price_usd ||
    token.market_cap_usd ||
    token.volume_24h_usd ||
    token.volume_7d_usd ||
    token.volume_30d_usd ||
    token.all_time_volume_kas ||
    typeof token.price_change_24h_percent === "number" ||
    typeof token.price_change_7d_percent === "number"
  )), [tokens]);
  const showMarketData = layer !== "L2" || hasMarketData;
  const isKrc721 = layer === "KRC721";
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    const scoped = favoritesOnly ? tokens.filter((token) => favoriteIds.has(token.id)) : tokens;
    if (!normalized) return scoped;
    return scoped.filter((token) => token.name.toLowerCase().includes(normalized) || token.symbol.toLowerCase().includes(normalized) || token.layer==='KCC20'&&(token.contract_address??token.id.replace(/^kcc20-/, '')).toLowerCase().includes(normalized));
  }, [tokens, query, favoritesOnly, favoriteIds]);
  const exactKrc20Match = useMemo(() => {
    if (layer !== "KRC20") return null;
    const normalized = query.trim().toUpperCase();
    if (!normalized) return null;
    return tokens.find((token) => token.symbol.toUpperCase() === normalized) || null;
  }, [layer, query, tokens]);
  const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
  const currentPage = Math.min(page, totalPages);
  const paged = useMemo(() => filtered.slice((currentPage - 1) * pageSize, currentPage * pageSize), [filtered, currentPage]);
  const title = favoritesOnly ? "Favorites" : layer === "KRC20" ? "KRC20 Explorer" : layer === "KCC20" ? "KCC20 Explorer" : layer === "KRC721" ? "KRC721 Explorer" : layer === "L2" ? "L2 Explorer" : "Combined Explorer";
  const eyebrow = favoritesOnly ? "Watchlist" : layer === "COMBINED" ? "KRC20 + L2 combined" : layer;
  const firstShown = filtered.length === 0 ? 0 : (currentPage - 1) * pageSize + 1;
  const lastShown = Math.min(currentPage * pageSize, filtered.length);

  useEffect(() => {
    setPage(1);
  }, [query, layer, favoritesOnly]);

  useEffect(() => {
    if (exactKrc20Match) {
      navigate("/token/" + encodeURIComponent(exactKrc20Match.id));
    }
  }, [exactKrc20Match, navigate]);

  useEffect(() => {
    const id=query.trim();
    if (layer==='KCC20' && /^[a-f0-9]{64}$/i.test(id)) navigate('/kcc20/'+id.toLowerCase());
  }, [query, layer, navigate]);

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (layer !== "KRC20") return;
    const target = exactKrc20Match || (filtered.length === 1 ? filtered[0] : null);
    if (target) {
      navigate("/token/" + encodeURIComponent(target.id));
    }
  }

  const pagination = (
    <div className="flex items-center gap-2">
      <button onClick={() => setPage((value) => Math.max(1, value - 1))} disabled={currentPage <= 1} className="focus-ring h-9 rounded-md border border-kaspa-border px-3 font-bold text-kaspa-text disabled:cursor-not-allowed disabled:opacity-40">Prev</button>
      <span>Page {currentPage} / {totalPages}</span>
      <button onClick={() => setPage((value) => Math.min(totalPages, value + 1))} disabled={currentPage >= totalPages} className="focus-ring h-9 rounded-md border border-kaspa-border px-3 font-bold text-kaspa-text disabled:cursor-not-allowed disabled:opacity-40">Next</button>
    </div>
  );
  const paginationBar = (
    <div className="flex flex-col gap-2 text-sm text-kaspa-muted sm:flex-row sm:items-center sm:justify-between">
      <span className="inline-flex items-center gap-2"><ListFilter className="h-4 w-4" aria-hidden="true" />Showing {firstShown}-{lastShown} of {filtered.length} tokens</span>
      {pagination}
    </div>
  );

  return (
    <section>
      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div><div className="text-sm font-bold tracking-wide text-kaspa-primary">{eyebrow}</div><h1 className="mt-1 text-3xl font-bold text-kaspa-text">{title}</h1></div>
      </div>
      {showMarketData && !isKrc721 && !favoritesOnly ? (
        <div className="mb-6 grid gap-4 lg:grid-cols-2">
          <MoverPanel title={"Top Gainers (" + movers.label + ")"} tokens={movers.gainers} changeField={movers.field} />
          <MoverPanel title={"Top Losers (" + movers.label + ")"} tokens={movers.losers} changeField={movers.field} />
        </div>
      ) : null}
      {showMarketData && isKrc721 && !favoritesOnly ? (
        <div className="mb-6">
          <MintingNowPanel tokens={mintingNow} />
        </div>
      ) : null}
      {showMarketData && !favoritesOnly ? (
        <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {isKrc721 ? <MetricTile label="24h Volume" value={formatKas(overview.volume24hKas)} tone="primary" /> : <MetricTile label="Market Cap" value={formatCurrency(overview.marketCapUsd)} tone="primary" />}
          {isKrc721 ? <MetricTile label="30d Volume" value={formatKas(overview.volume30dKas)} /> : <MetricTile label="24h Volume" value={formatCurrency(overview.volume24hUsd)} />}
          {isKrc721 ? <MetricTile label="All Time Volume" value={formatKas(overview.allTimeKas)} /> : <MetricTile label="Verified" value={String(overview.verified)} />}
        </div>
      ) : !favoritesOnly ? (
        <div className="kaspa-panel mb-6 rounded-md p-4">
          <div className="text-xs font-semibold text-kaspa-primary">L2 token discovery</div>
          <div className="mt-2 text-sm text-kaspa-muted">L2 tokens are discovered from configured DEX factory contracts. Price, market cap, volume and gain/loss data need a separate L2 pair/reserve/event indexer and are intentionally hidden until that data exists.</div>
        </div>
      ) : null}
      <div className="mb-4 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <form onSubmit={submitSearch} className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <label className="focus-within:shadow-kaspa flex h-10 min-w-[280px] items-center gap-2 rounded-md border border-kaspa-border bg-kaspa-card px-3 transition focus-within:border-kaspa-primary">
            <Search className="h-4 w-4 text-kaspa-muted" aria-hidden="true" />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={layer === "KRC20" ? "Search ticker, opens exact match" : "Search token"} className="w-full bg-transparent text-sm text-kaspa-text outline-none placeholder:text-kaspa-muted" />
          </label>
        </form>
        {!isKrc721 ? <div className="text-sm text-kaspa-muted">{favoritesOnly ? "Showing favorites only." : "Unverified means too little or no volume."}</div> : null}
      </div>
      <div className="mb-4">{paginationBar}</div>
      {!favoritesOnly && (layer === "KRC20" || layer === "COMBINED") ? (
        <div className="mb-4 text-sm text-kaspa-muted">
          24h volume reflects available marketplaces. Longer-range volume follows the sources reported for this asset.
        </div>
      ) : null}
      {!favoritesOnly && layer === "L2" ? (
        <div className="mb-4 text-sm text-kaspa-muted">
          24h volume reflects all DEX&apos;es, 7d and 30d only KaspaCom DEX. Zealous Swap only provides limited data
        </div>
      ) : null}
      {tokensState.loading ? <LoadingState /> : null}
      {tokensState.error ? <EmptyState title="API unavailable" body={tokensState.error} /> : null}
      {!tokensState.loading && !tokensState.error && filtered.length === 0 ? <EmptyState title={favoritesOnly ? "No favorites found" : "No tokens found"} body={favoritesOnly ? "Use the star on tokens you want to watch, then return to this filtered view." : undefined} /> : null}
      {!tokensState.loading && !tokensState.error && filtered.length > 0 ? <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{paged.map((token) => <TokenCard key={token.id} token={token} rank={rankById.get(token.id) || 0} showMarketData={showMarketData} />)}</div> : null}
      {!tokensState.loading && !tokensState.error && filtered.length > pageSize ? (
        <div className="mt-5">{paginationBar}</div>
      ) : null}
    </section>
  );
}

function MintingNowPanel({ tokens }: { tokens: Token[] }) {
  return (
    <div className="kaspa-panel rounded-md p-4">
      <div className="text-xs font-semibold text-kaspa-muted">Minting right now</div>
      <div className="mt-1 text-[11px] text-kaspa-muted">Collections with mint activity in the last 24h.</div>
      {tokens.length === 0 ? (
        <div className="mt-5 rounded-sm border border-kaspa-border bg-kaspa-background/60 px-3 py-4 text-sm text-kaspa-muted">
          Waiting for next mint snapshot. KRC721 APIs expose total minted/max supply, so 24h mint activity is calculated from backend snapshot deltas and recent indexer updates.
        </div>
      ) : (
        <div className="mt-4 grid gap-3 lg:grid-cols-3">
          {tokens.map((token) => (
            <Link key={token.id} to={"/token/" + encodeURIComponent(token.id)} className="focus-ring grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3 rounded-sm border border-kaspa-border bg-kaspa-background/50 px-3 py-3 transition hover:border-kaspa-primary/70 hover:bg-kaspa-primary/5">
              <TokenLogo src={token.image_url} symbol={token.symbol} size="sm" />
              <span className="min-w-0">
                <span className="block truncate text-sm font-bold text-kaspa-text">{token.symbol}</span>
                <span className="block text-xs text-kaspa-muted">{formatPlainPercent(token.mint_percent)} minted</span>
              </span>
              <span className="text-right">
                <span className="block text-sm font-bold text-kaspa-primary">+{formatInteger(token.mint_activity_count)}</span>
                <span className="block text-[11px] text-kaspa-muted">new</span>
              </span>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

function sortExplorerTokens(tokens: Token[], layer: ExplorerLayer) {
  return [...tokens].sort((a, b) => {
    if (layer === "KRC721") {
      return (b.volume_30d_kas || 0) - (a.volume_30d_kas || 0)
        || (b.volume_7d_kas || 0) - (a.volume_7d_kas || 0)
        || (b.volume_24h_kas || 0) - (a.volume_24h_kas || 0)
        || (b.all_time_volume_kas || 0) - (a.all_time_volume_kas || 0)
        || a.symbol.localeCompare(b.symbol);
    }

    if (layer === "KCC20") {
      return compareKcc20Tokens(a, b);
    }

    if (isDagasWarningToken(a) !== isDagasWarningToken(b)) {
      return isDagasWarningToken(a) ? 1 : -1;
    }

    const aUnusual = isUnusualMarketCap(a);
    const bUnusual = isUnusualMarketCap(b);
    if (aUnusual !== bUnusual) {
      return aUnusual ? 1 : -1;
    }

    if (a.verified !== b.verified) {
      return a.verified ? -1 : 1;
    }

    if (layer === "COMBINED" && a.verified && b.verified) {
      const marketCapDiff = (b.market_cap_usd || 0) - (a.market_cap_usd || 0);
      if (marketCapDiff !== 0) {
        return marketCapDiff;
      }
      return (b.volume_30d_usd || 0) - (a.volume_30d_usd || 0);
    }
    if (!a.verified && !b.verified) {
      const volumeDiff =
        sortVolume(b) - sortVolume(a) ||
        (b.volume_30d_usd || 0) - (a.volume_30d_usd || 0) ||
        (b.volume_7d_usd || 0) - (a.volume_7d_usd || 0) ||
        (b.volume_24h_usd || 0) - (a.volume_24h_usd || 0);
      if (volumeDiff !== 0) {
        return volumeDiff;
      }
    }
    return (b.market_cap_usd || 0) - (a.market_cap_usd || 0);
  });
}

function normalizeExplorerToken(token: Token): Token {
  if (isDagasWarningToken(token)) {
    return {
      ...token,
      verified: false,
      unusual_market_cap: true,
      verification_reason: "100% dev minted airdrop token. Metrics have been reported to be not real."
    };
  }
  const unusual = isUnusualMarketCap(token);
  if (token.layer !== "L2") {
    return unusual ? { ...token, unusual_market_cap: true } : token;
  }

  const verification = activityVerification(token);
  const verified = verification.verified && (token.price_kas !== null || token.price_usd !== null);
  return {
    ...token,
    verified,
    unusual_market_cap: unusual || undefined,
    verification_reason: verified
      ? `Activity volume meets the requirement for this market cap tier: ${verification.requirement}.`
      : `Unverified: too little or no volume. Required: ${verification.requirement}. DEX volume is included where indexed.`
  };
}

function isUnusualMarketCap(token: Token) {
  if (token.layer === "KRC721") {
    return false;
  }
  if (token.symbol.toUpperCase() === "ZEAL") {
    return false;
  }
  const computed = (token.market_cap_usd ?? 0) > 1_000_000 && !activityVerification(token).verified;
  return token.layer === "L2" ? computed : Boolean(token.unusual_market_cap) || computed;
}

function isDagasWarningToken(token: Token) {
  return token.layer === "KRC20" && token.symbol.trim().toUpperCase() === "DAGAS";
}

function activityVerification(token: Token) {
  if (token.layer === "KRC20" && (token.market_cap_usd ?? 0) >= 500_000) {
    const verified = (token.volume_24h_usd || 0) >= 500 || (token.volume_30d_usd || 0) >= 2_000;
    return {
      verified,
      requiredVolumeUsd: 2_000,
      requirement: "at least 500 USD 24H volume or 2,000 USD 30D volume"
    };
  }
  const requiredVolumeUsd = requiredActivityVolumeUsd(token);
  if (activityVolume(token) >= requiredVolumeUsd) {
    return { verified: true, requiredVolumeUsd, requirement: `${requiredVolumeUsd} USD activity volume` };
  }
  if ((token.layer === "KRC20" || token.layer === "L2") && twentyFourHourOnlyMarketVolume(token) >= 50) {
    return { verified: true, requiredVolumeUsd: 50, requirement: "50 USD 24H DEX volume" };
  }
  return { verified: false, requiredVolumeUsd, requirement: `${requiredVolumeUsd} USD activity volume` };
}

function sortVolume(token: Token) {
  if (token.layer === "KRC721") {
    return krc721RankScore(token);
  }
  return token.layer === "L2" || isTwentyFourHourOnly(token) ? activityVolume(token) : token.volume_30d_usd || 0;
}

function activityVolume(token: Token) {
  if (isTwentyFourHourOnly(token)) {
    return token.volume_24h_usd || 0;
  }
  return Math.max(token.volume_30d_usd || 0, token.volume_7d_usd || 0, token.volume_24h_usd || 0);
}

function requiredActivityVolumeUsd(token: Token) {
  if (isTwentyFourHourOnly(token)) {
    return 50;
  }
  if (token.layer === "KRC20" && token.symbol.trim().toUpperCase() === "KREX") {
    return 150;
  }
  const marketCap = token.market_cap_usd ?? 0;
  if (marketCap > 300000) {
    return 500;
  }
  if (marketCap >= 100000) {
    return 250;
  }
  return 50;
}

function isTwentyFourHourOnly(token: Token) {
  if ((token.volume_30d_usd || 0) > 0 || (token.volume_7d_usd || 0) > 0) {
    return false;
  }
  return (token.layer === "KRC20" || token.layer === "L2") && (
    token.volume_7d_available === false && token.volume_30d_available === false ||
    hasTwentyFourHourOnlyMarket(token)
  );
}

function hasTwentyFourHourOnlyMarket(token: Token) {
  return twentyFourHourOnlyMarketVolume(token) > 0;
}

function twentyFourHourOnlyMarketVolume(token: Token) {
  return (token.markets || []).reduce((sum, market) =>
    market.type === "DEX" &&
    market.volume_7d_available === false &&
    market.volume_30d_available === false &&
    (market.volume_24h_usd || 0) > 0
      ? sum + (market.volume_24h_usd || 0)
      : sum, 0);
}

function krc721RankScore(token: Token) {
  return token.volume_30d_kas || token.volume_7d_kas || token.volume_24h_kas || token.all_time_volume_kas || 0;
}

