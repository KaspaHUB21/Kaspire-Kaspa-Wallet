import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowRight, CheckCircle2, CircleDashed, DatabaseZap, LayoutGrid, Search, Table2 } from "../components/icons";
import { DirectionalPercent } from "../components/DirectionalPercent";
import { EmptyState } from "../components/EmptyState";
import { FavoriteButton } from "../components/FavoriteButton";
import { LoadingState } from "../components/LoadingState";
import { MetricTile } from "../components/MetricTile";
import { TokenLogo } from "../components/TokenLogo";
import { useKcc20DexMarkets, useKcc20Tokens } from "../services/tokens";
import type { Kcc20DexMarket, Kcc20Token } from "../types/token";
import { formatInteger, formatKas, formatKcc20Amount } from "../utils/format";

type DataMode = "dex" | "indexed";
type ViewMode = "grid" | "table";

const pageSize = 15;
const dataModeKey = "kashub-kcc20-data-mode-v1";
const viewModeKey = "kaspa-token-explorer-view-mode-v1";

export function Kcc20Page() {
  const indexedState = useKcc20Tokens();
  const dexState = useKcc20DexMarkets();
  const [mode, setMode] = useState<DataMode>(() => readDataMode());
  const [view, setView] = useState<ViewMode>(() => readViewMode());
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(1);
  const indexedTokens = indexedState.data?.tokens || [];
  const indexedById = useMemo(() => new Map(indexedTokens.map((token) => [token.covenant_id, token])), [indexedTokens]);
  const markets = useMemo(
    () => [...(dexState.data?.markets || [])].sort((a, b) => (b.market_cap_kas || 0) - (a.market_cap_kas || 0) || b.volume_24h_kas - a.volume_24h_kas),
    [dexState.data]
  );
  const rankByCovenantId = useMemo(() => new Map(markets.map((market, index) => [market.covenant_id, index + 1])), [markets]);
  const normalizedQuery = query.trim().toLowerCase();
  const filteredMarkets = useMemo(() => markets.filter((market) =>
    !normalizedQuery ||
    market.ticker.toLowerCase().includes(normalizedQuery) ||
    market.name.toLowerCase().includes(normalizedQuery) ||
    market.covenant_id.includes(normalizedQuery)
  ), [markets, normalizedQuery]);
  const filteredIndexed = useMemo(() => indexedTokens.filter((token) =>
    !normalizedQuery ||
    token.name.toLowerCase().includes(normalizedQuery) ||
    (token.claimed_name || "").toLowerCase().includes(normalizedQuery) ||
    tickerFor(token).toLowerCase().includes(normalizedQuery) ||
    token.covenant_id.includes(normalizedQuery)
  ), [indexedTokens, normalizedQuery]);
  const activeItems = mode === "dex" ? filteredMarkets : filteredIndexed;
  const totalPages = Math.max(1, Math.ceil(activeItems.length / pageSize));
  const currentPage = Math.min(page, totalPages);
  const visibleMarkets = filteredMarkets.slice((currentPage - 1) * pageSize, currentPage * pageSize);
  const visibleIndexed = filteredIndexed.slice((currentPage - 1) * pageSize, currentPage * pageSize);
  const overview = useMemo(() => markets.reduce((total, market) => ({
    marketCap: total.marketCap + (market.market_cap_kas || 0),
    volume: total.volume + market.volume_24h_kas,
    tvl: total.tvl + market.tvl_kas
  }), { marketCap: 0, volume: 0, tvl: 0 }), [markets]);
  const gainers = useMemo(() => markets.filter((market) => (market.change_24h_percent || 0) > 0).sort((a, b) => (b.change_24h_percent || 0) - (a.change_24h_percent || 0)).slice(0, 5), [markets]);
  const losers = useMemo(() => markets.filter((market) => (market.change_24h_percent || 0) < 0).sort((a, b) => (a.change_24h_percent || 0) - (b.change_24h_percent || 0)).slice(0, 5), [markets]);

  useEffect(() => {
    setPage(1);
  }, [query, mode]);

  useEffect(() => {
    localStorage.setItem(dataModeKey, mode);
  }, [mode]);

  useEffect(() => {
    localStorage.setItem(viewModeKey, view);
  }, [view]);

  const pagination = activeItems.length > 0 ? (
    <div className="flex flex-col gap-2 text-sm text-kaspa-muted sm:flex-row sm:items-center sm:justify-between">
      <span>Showing {(currentPage - 1) * pageSize + 1}-{Math.min(currentPage * pageSize, activeItems.length)} of {activeItems.length} tokens</span>
      <div className="flex items-center gap-2">
        <button onClick={() => setPage((value) => Math.max(1, value - 1))} disabled={currentPage <= 1} className="focus-ring h-9 rounded-md border border-kaspa-border px-3 font-bold text-kaspa-text disabled:opacity-40">Prev</button>
        <span>Page {currentPage} / {totalPages}</span>
        <button onClick={() => setPage((value) => Math.min(totalPages, value + 1))} disabled={currentPage >= totalPages} className="focus-ring h-9 rounded-md border border-kaspa-border px-3 font-bold text-kaspa-text disabled:opacity-40">Next</button>
      </div>
    </div>
  ) : null;

  return (
    <section>
      <div className="mb-5">
        <div className="text-sm font-bold text-kaspa-primary">KCC20 · Kaspa Mainnet</div>
        <h1 className="mt-1 text-3xl font-bold text-kaspa-text">KCC20 Explorer</h1>
      </div>

      <div className="mb-6 inline-flex rounded-md border border-kaspa-border bg-kaspa-card p-1">
        <button onClick={() => setMode("dex")} className={modeButton(mode === "dex")}>DEX Data</button>
        <button onClick={() => setMode("indexed")} className={modeButton(mode === "indexed")}>Indexed KCC20 Tokens</button>
      </div>

      {mode === "dex" ? (
        <>
          <div className="mb-6 grid gap-4 lg:grid-cols-2">
            <DexMoverPanel title="Top Gainers (24h)" markets={gainers} indexedById={indexedById} />
            <DexMoverPanel title="Top Losers (24h)" markets={losers} indexedById={indexedById} />
          </div>
          <div className="mb-6 grid gap-3 sm:grid-cols-3">
            <MetricTile label="Market Cap" value={formatKas(overview.marketCap)} tone="primary" />
            <MetricTile label="24h Volume" value={formatKas(overview.volume)} />
            <MetricTile label="TVL" value={formatKas(overview.tvl)} />
          </div>
        </>
      ) : (
        <div className="kaspa-panel mb-6 rounded-md border-kaspa-primary/40 p-4">
          <div className="flex items-start gap-3">
            <DatabaseZap className="mt-0.5 h-5 w-5 shrink-0 text-kaspa-primary" />
            <div>
              <div className="font-bold text-kaspa-text">Complete Mainnet index</div>
              <p className="mt-1 text-sm text-kaspa-muted">All indexed KCC20 tokens, including covenants without a KaspaRocket market.</p>
            </div>
          </div>
        </div>
      )}

      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <label className="focus-within:shadow-kaspa flex h-10 min-w-0 max-w-xl flex-1 items-center gap-2 rounded-md border border-kaspa-border bg-kaspa-card px-3 focus-within:border-kaspa-primary">
          <Search className="h-4 w-4 shrink-0 text-kaspa-muted" />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search name, ticker or covenant ID" className="min-w-0 flex-1 bg-transparent text-sm text-kaspa-text outline-none placeholder:text-kaspa-muted" />
        </label>
        {mode === "dex" ? (
          <div className="flex h-10 rounded-md border border-kaspa-border bg-kaspa-card p-1">
            <button onClick={() => setView("grid")} className={viewButton(view === "grid")} title="Grid view"><LayoutGrid className="h-4 w-4" /></button>
            <button onClick={() => setView("table")} className={viewButton(view === "table")} title="Table view"><Table2 className="h-4 w-4" /></button>
          </div>
        ) : null}
      </div>

      <div className="mb-4">{pagination}</div>
      {(mode === "dex" ? dexState.loading : indexedState.loading) ? <LoadingState /> : null}
      {(mode === "dex" ? dexState.error : indexedState.error) ? <EmptyState title="KCC20 data unavailable" body={(mode === "dex" ? dexState.error : indexedState.error) || undefined} /> : null}
      {!activeItems.length && !(mode === "dex" ? dexState.loading : indexedState.loading) ? <EmptyState title="No KCC20 tokens found" /> : null}

      {mode === "dex" && visibleMarkets.length > 0 && view === "grid" ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {visibleMarkets.map((market) => <DexMarketCard key={market.covenant_id} market={market} token={indexedById.get(market.covenant_id)} rank={rankByCovenantId.get(market.covenant_id) || 0} />)}
        </div>
      ) : null}
      {mode === "dex" && visibleMarkets.length > 0 && view === "table" ? <DexMarketTable markets={visibleMarkets} indexedById={indexedById} rankByCovenantId={rankByCovenantId} /> : null}
      {mode === "indexed" && visibleIndexed.length > 0 ? <IndexedTokenTable tokens={visibleIndexed} /> : null}

      {activeItems.length > pageSize ? <div className="mt-5">{pagination}</div> : null}
    </section>
  );
}

function DexMoverPanel({ title, markets, indexedById }: { title: string; markets: Kcc20DexMarket[]; indexedById: Map<string, Kcc20Token> }) {
  return (
    <div className="kaspa-panel rounded-md p-4">
      <div className="mb-3 font-bold text-kaspa-text">{title}</div>
      <div className="space-y-2">
        {markets.length === 0 ? <div className="py-5 text-sm text-kaspa-muted">No matching market moves.</div> : markets.map((market) => {
          const token = indexedById.get(market.covenant_id);
          return (
            <Link key={market.covenant_id} to={`/kcc20/${market.covenant_id}`} className="focus-ring flex items-center gap-3 rounded-sm border border-kaspa-border bg-kaspa-background/40 px-3 py-2 hover:border-kaspa-primary/60">
              <TokenLogo src={token?.image_url || market.image_url || undefined} symbol={market.ticker} size="sm" />
              <span className="min-w-0 flex-1 truncate font-bold text-kaspa-text">{market.ticker}</span>
              <DexChange value={market.change_24h_percent} />
            </Link>
          );
        })}
      </div>
    </div>
  );
}

function DexMarketCard({ market, token, rank }: { market: Kcc20DexMarket; token?: Kcc20Token; rank: number }) {
  return (
    <article className="kaspa-panel rounded-md p-4">
      <div className="flex items-start gap-3">
        <Link to={`/kcc20/${market.covenant_id}`} className="focus-ring flex min-w-0 flex-1 items-center gap-3 rounded-sm">
          <TokenLogo src={token?.image_url || market.image_url || undefined} symbol={market.ticker} size="md" />
          <span className="min-w-0">
            <span className="block truncate text-lg font-bold text-kaspa-text">{market.ticker}</span>
            <span className="block truncate text-xs text-kaspa-muted">{market.name}</span>
          </span>
        </Link>
        <div className="flex shrink-0 items-center gap-2">
          <span className="text-sm font-bold text-kaspa-muted">#{rank}</span>
          <FavoriteButton tokenId={`kcc20-${market.covenant_id}`} compact />
        </div>
      </div>
      <div className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
        <DexValue label="Price" value={formatKas(market.price_kas)} primary />
        <div className="text-right"><div className="text-xs text-kaspa-muted">24h</div><div className="mt-1"><DexChange value={market.change_24h_percent} /></div></div>
        <DexValue label="24h Volume" value={formatKas(market.volume_24h_kas)} />
        <DexValue label="Market Cap" value={formatKas(market.market_cap_kas)} right />
        <DexValue label="TVL" value={formatKas(market.tvl_kas)} />
        <DexValue label="Holders" value={formatInteger(token?.holders || market.holders)} right />
      </div>
      <div className="mt-4 flex items-center justify-between border-t border-kaspa-border pt-3 text-xs">
        <span className="rounded-sm border border-kaspa-primary/40 px-2 py-1 text-kaspa-primary">{market.graduated ? "AMM Pool" : "Bonding Curve"}</span>
        <Link to={`/kcc20/${market.covenant_id}`} className="focus-ring rounded-sm text-kaspa-primary hover:underline">View market</Link>
      </div>
    </article>
  );
}

function DexMarketTable({ markets, indexedById, rankByCovenantId }: { markets: Kcc20DexMarket[]; indexedById: Map<string, Kcc20Token>; rankByCovenantId: Map<string, number> }) {
  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="overflow-x-auto">
        <table className="min-w-[1050px] divide-y divide-kaspa-border text-sm">
          <thead className="bg-kaspa-background/60 text-xs font-semibold text-kaspa-muted"><tr><th className="px-3 py-3 text-left">Rank</th><th className="px-3 py-3 text-left">Token</th><th className="px-3 py-3 text-right">Price</th><th className="px-3 py-3 text-right">24h</th><th className="px-3 py-3 text-right">24h Vol</th><th className="px-3 py-3 text-right">Market Cap</th><th className="px-3 py-3 text-right">TVL</th><th className="px-3 py-3 text-right">Holders</th><th className="px-3 py-3 text-right">Market</th></tr></thead>
          <tbody className="divide-y divide-kaspa-border">
            {markets.map((market) => {
              const token = indexedById.get(market.covenant_id);
              return <tr key={market.covenant_id} className="hover:bg-kaspa-primary/5"><td className="whitespace-nowrap px-3 py-3"><div className="flex items-center gap-2"><span className="font-bold text-kaspa-muted">#{rankByCovenantId.get(market.covenant_id) || "-"}</span><FavoriteButton tokenId={`kcc20-${market.covenant_id}`} compact bare /></div></td><td className="px-3 py-3"><Link to={`/kcc20/${market.covenant_id}`} className="focus-ring flex min-w-0 items-center gap-3 rounded-sm"><TokenLogo src={token?.image_url || market.image_url || undefined} symbol={market.ticker} size="sm" /><span><span className="block font-bold text-kaspa-text">{market.ticker}</span><span className="block text-xs text-kaspa-muted">{market.name}</span></span></Link></td><td className="px-3 py-3 text-right font-bold text-kaspa-text">{formatKas(market.price_kas)}</td><td className="px-3 py-3 text-right"><DexChange value={market.change_24h_percent} /></td><td className="px-3 py-3 text-right">{formatKas(market.volume_24h_kas)}</td><td className="px-3 py-3 text-right">{formatKas(market.market_cap_kas)}</td><td className="px-3 py-3 text-right">{formatKas(market.tvl_kas)}</td><td className="px-3 py-3 text-right">{formatInteger(token?.holders || market.holders)}</td><td className="px-3 py-3 text-right text-xs text-kaspa-primary">{market.graduated ? "AMM Pool" : "Bonding Curve"}</td></tr>;
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function IndexedTokenTable({ tokens }: { tokens: Kcc20Token[] }) {
  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="divide-y divide-kaspa-border md:hidden">{tokens.map((token) => <IndexedMobileToken key={token.covenant_id} token={token} />)}</div>
      <div className="hidden overflow-x-auto md:block">
        <table className="min-w-full divide-y divide-kaspa-border text-sm">
          <thead className="bg-kaspa-background/60 text-xs font-semibold text-kaspa-muted"><tr><th className="px-4 py-3 text-left">Token</th><th className="px-4 py-3 text-left">Covenant ID</th><th className="px-4 py-3 text-right">Supply</th><th className="px-4 py-3 text-right">Holders</th><th className="px-4 py-3 text-right">Actions</th><th className="px-4 py-3 text-right">Standard</th><th className="px-4 py-3 text-right">Status</th></tr></thead>
          <tbody className="divide-y divide-kaspa-border">{tokens.map((token) => <tr key={token.covenant_id} className="hover:bg-kaspa-primary/5"><td className="px-4 py-3"><IndexedTokenLink token={token} /></td><td className="max-w-[260px] px-4 py-3"><div className="truncate font-mono text-xs text-kaspa-muted">{token.covenant_id}</div></td><td className="px-4 py-3 text-right font-semibold">{formatKcc20Amount(token.supply, token.decimals)}</td><td className="px-4 py-3 text-right">{formatInteger(token.holders)}</td><td className="px-4 py-3 text-right">{formatInteger(token.action_count)}</td><td className="px-4 py-3 text-right text-xs text-kaspa-muted">{standardLabel(token.standard)}</td><td className="px-4 py-3 text-right"><ValidationBadge token={token} /></td></tr>)}</tbody>
        </table>
      </div>
    </div>
  );
}

function IndexedMobileToken({ token }: { token: Kcc20Token }) {
  return <article className="p-4"><div className="flex items-center gap-3"><div className="min-w-0 flex-1"><IndexedTokenLink token={token} /></div><ValidationBadge token={token} /><Link to={`/kcc20/${token.covenant_id}`}><ArrowRight className="h-4 w-4 text-kaspa-primary" /></Link></div><div className="mt-4 grid grid-cols-2 gap-3 text-sm"><DexValue label="Supply" value={formatKcc20Amount(token.supply, token.decimals)} /><DexValue label="Holders" value={formatInteger(token.holders)} right /><DexValue label="Actions" value={formatInteger(token.action_count)} /><DexValue label="Standard" value={standardLabel(token.standard)} right /></div></article>;
}

function IndexedTokenLink({ token }: { token: Kcc20Token }) {
  const ticker = tickerFor(token);
  const title = ticker || token.claimed_name || token.name;
  return <Link to={`/kcc20/${token.covenant_id}`} className="focus-ring flex min-w-0 items-center gap-3 rounded-sm"><TokenLogo src={token.image_url || undefined} symbol={title} size="sm" /><span className="min-w-0"><span className="block truncate font-bold text-kaspa-text">{title}</span>{token.name !== title ? <span className="block truncate text-xs text-kaspa-muted">{token.name}</span> : null}</span></Link>;
}

function ValidationBadge({ token }: { token: Kcc20Token }) {
  const verified = token.status === "verified" || token.status === "template_verified";
  return <span className={["inline-flex h-7 w-7 items-center justify-center rounded-md border", verified ? "border-kaspa-primary/60 bg-kaspa-primary/10 text-kaspa-primary" : token.status === "invalid" ? "border-red-500/60 bg-red-500/10 text-red-400" : "border-kaspa-border text-kaspa-muted"].join(" ")} title={verified ? "On-chain history verified" : token.invalid_reason || "On-chain history unvalidated"}>{verified ? <CheckCircle2 className="h-4 w-4" /> : <CircleDashed className="h-4 w-4" />}</span>;
}

function DexValue({ label, value, primary = false, right = false }: { label: string; value: string; primary?: boolean; right?: boolean }) {
  return <div className={right ? "text-right" : ""}><div className="text-xs text-kaspa-muted">{label}</div><div className={["mt-1 font-semibold", primary ? "text-kaspa-primary" : "text-kaspa-text"].join(" ")}>{value}</div></div>;
}

function DexChange({ value }: { value: number | null }) {
  const color = value === null || value === 0 ? undefined : { color: value > 0 ? "#00FF00" : "#FF0000" };
  return <span className="font-normal text-kaspa-muted" style={color}><DirectionalPercent value={value} /></span>;
}

function modeButton(active: boolean) {
  return ["focus-ring rounded-sm px-4 py-2 text-sm font-bold transition", active ? "bg-kaspa-primary/10 text-kaspa-primary shadow-kaspa" : "text-kaspa-muted hover:text-kaspa-primary"].join(" ");
}

function viewButton(active: boolean) {
  return ["focus-ring rounded-sm px-2 transition", active ? "bg-kaspa-primary/10 text-kaspa-primary" : "text-kaspa-muted hover:text-kaspa-primary"].join(" ");
}

function tickerFor(token: Kcc20Token) {
  return token.claimed_ticker || token.fields.tick || token.fields.ticker || "";
}

function standardLabel(standard: string | null) {
  return standard === "legacy-kcc20" ? "Legacy KCC20" : standard || "n/a";
}

function readDataMode(): DataMode {
  try {
    return localStorage.getItem(dataModeKey) === "indexed" ? "indexed" : "dex";
  } catch {
    return "dex";
  }
}

function readViewMode(): ViewMode {
  try {
    return localStorage.getItem(viewModeKey) === "table" ? "table" : "grid";
  } catch {
    return "grid";
  }
}

