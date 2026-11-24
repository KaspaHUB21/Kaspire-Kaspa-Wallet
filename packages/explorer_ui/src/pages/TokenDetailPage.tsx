import {NftGallery} from '../NftGallery';
import { ArrowLeft, BarChart3, Calculator, Layers3, List, PieChart, Store, Users } from "../components/icons";
import { useEffect, useState, type ComponentProps } from "react";
import { Link, Navigate, useParams } from "react-router-dom";
import { EmptyState } from "../components/EmptyState";
import { FavoriteButton } from "../components/FavoriteButton";
import { HolderTable } from "../components/HolderTable";
import { MetricTile as BaseMetricTile } from "../components/MetricTile";
import { PriceChart } from "../components/PriceChart";
import { StatusBadge } from "../components/StatusBadge";
import { TokenLogo } from "../components/TokenLogo";
import { TxTable } from "../components/TxTable";
import { WalletLabelBadge } from "../components/WalletLabelBadge";
import { getHolders, getTransactions } from "../services/api";
import { useToken, useTokenCollections } from "../services/tokens";
import { useWalletLabels } from "../services/walletLabels";
import type { ChartRange, Holder, Token, TokenMarket, TokenTransaction, TransactionType } from "../types/token";
import { formatAgeSince, formatCompact, formatCurrency, formatCurrencyWindow, formatDateTime, formatInteger, formatKas, formatKasVolume, formatPlainPercent, formatTokenAmount } from "../utils/format";
import { hasVolumeWindow } from "../utils/token";

type DetailTab = "overview" | "market" | "holders" | "transactions" | "analytics" | "web" | "converter";

const tabs: Array<{ id: DetailTab; label: string; icon: typeof BarChart3 }> = [
  { id: "overview", label: "Overview", icon: BarChart3 },
  { id: "market", label: "Market", icon: Store },
  { id: "holders", label: "Holders", icon: Users },
  { id: "transactions", label: "Transactions", icon: List },
  { id: "analytics", label: "Analytics", icon: PieChart },
  { id: "web", label: "Web & Socials", icon: Store },
  { id: "converter", label: "Price Converter", icon: Calculator }
];

function MetricTile(props: ComponentProps<typeof BaseMetricTile>) {
  return <BaseMetricTile {...props} variant="detail" />;
}

function priceChangeForRange(token: Token, range: ChartRange) {
  if (isDexDrivenKrc20(token)) {
    return null;
  }
  if (range === "24h") {
    return token.price_change_24h_percent;
  }
  if (range === "7d") {
    return token.price_change_7d_percent;
  }
  return null;
}

function isDexDrivenKrc20(token: Token) {
  if (token.layer !== "KRC20") {
    return false;
  }
  const markets = token.markets || [];
  const dexVolume = markets
    .filter((market) => market.type === "DEX")
    .reduce((sum, market) => sum + (market.volume_24h_usd || market.volume_7d_usd || market.volume_30d_usd || 0), 0);
  const l1Volume = markets
    .filter((market) => market.type === "L1_MARKETPLACE")
    .reduce((sum, market) => sum + (market.volume_24h_usd || market.volume_7d_usd || market.volume_30d_usd || 0), 0);
  return dexVolume > 0 && dexVolume >= l1Volume;
}

export function TokenDetailPage() {
  const { id } = useParams();
  const [tab, setTab] = useState<DetailTab>("overview");
  const [range, setRange] = useState<ChartRange>("30d");
  const [txType, setTxType] = useState<TransactionType | undefined>(undefined);
  const tokenState = useToken(id);
  const token = tokenState.data ? {...tokenState.data,markets:tokenState.data.markets?.filter(m=>!/(igra|kasplex)/i.test(m.network??'')&&!/^0x/i.test(m.contract_address??''))} : null;
  const isL2 = token?.layer === "L2";
  const isKrc721 = token?.layer === "KRC721";
  const flaggedDagas = token ? isDagasWarningToken(token) : false;
  const collections = useTokenCollections(id, range, Boolean(token) && !isKrc721 && !isL2);

  useEffect(() => {
    setRange("30d");
  }, [id]);

  useEffect(() => {
    if (isKrc721 && tab !== "overview") {
      setTab("overview");
    }
  }, [isKrc721, tab]);

  if (isL2) return <Navigate to="/" replace />;
  if (tokenState.loading) return <div className="kaspa-panel h-80 animate-pulse rounded-md" />;
  if (tokenState.error || !token) return id?.startsWith('krc721-')?<section><Link to="/krc721">← Collections</Link><p className="my-3 text-kaspa-muted">Collection metrics are temporarily unavailable. NFT images, traits and ranks load independently.</p><NftGallery ticker={id.replace(/^krc721-/,'').toUpperCase()}/></section>:<EmptyState title="Token data temporarily unavailable" body="Please retry shortly." />;
  const contractUrl = isL2 && token.contract_address ? l2ContractUrl(token.id, token.contract_address) : null;
  const visibleTabs = isKrc721 ? [] : tabs;
  const burnedPercent = !isL2 && !isKrc721 && token.burned_supply !== undefined && token.burned_supply !== null && token.total_supply
    ? token.burned_supply / token.total_supply * 100
    : null;

  return (
    <section>
      <Link to={isL2 ? "/l2" : isKrc721 ? "/krc721" : "/krc20"} className="focus-ring mb-5 inline-flex items-center gap-2 rounded-md text-sm font-semibold text-kaspa-muted hover:text-kaspa-primary">
        <ArrowLeft className="h-4 w-4" aria-hidden="true" /> Back
      </Link>

      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex items-center gap-4">
          <TokenLogo src={token.image_url} symbol={token.symbol} size="lg" />
          <div>
            <div className="flex flex-wrap items-center gap-3">
              <h1 className="flex items-center gap-2 text-3xl font-bold text-kaspa-text">
                <span>{token.symbol}</span>
                {flaggedDagas ? <span className="text-2xl font-black leading-none text-red-500" title="100% dev minted airdrop token. Metrics have been reported to be not real.">*</span> : null}
              </h1>
              <FavoriteButton tokenId={token.id} />
              {!isKrc721 ? <StatusBadge verified={token.verified} reason={token.verification_reason} /> : null}
            </div>
            {!isL2 && !isKrc721 ? <PremintBadge percent={token.premint_percent} /> : null}
            {isL2 && token.contract_address ? (
              <div className="mt-2 max-w-[min(680px,calc(100vw-3rem))] text-xs">
                <span className="mr-2 font-semibold text-kaspa-muted">Contract</span>
                {contractUrl ? (
                  <a href={contractUrl} target="_blank" rel="noreferrer" className="break-all font-mono text-kaspa-primary hover:underline">{token.contract_address}</a>
                ) : (
                  <span className="break-all font-mono text-kaspa-muted">{token.contract_address}</span>
                )}
              </div>
            ) : null}
          </div>
        </div>
        {isKrc721 && token.browse_url ? (
          <a href={token.browse_url} target="_blank" rel="noreferrer" className="focus-ring inline-flex h-12 items-center justify-center rounded-md border border-kaspa-primary bg-kaspa-primary px-5 text-sm font-black text-kaspa-background shadow-kaspa transition hover:bg-kaspa-primary/80">
            Browse collection
          </a>
        ) : null}
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:min-w-[520px]">
          <MetricTile label={isKrc721 ? "Floor" : "Price"} value={formatKas(token.price_kas)} tone="primary" />
          {isKrc721 ? <MetricTile label="30d Volume" value={formatKasVolume(token.volume_30d_kas)} /> : <MetricTile label="USD" value={formatCurrency(token.price_usd)} />}
          {isKrc721 ? <MetricTile label="All Time Volume" value={formatKasVolume(token.all_time_volume_kas)} /> : <MetricTile label="Market Cap" value={token.unusual_market_cap ? `* Unusual market cap detected (${formatCurrency(token.market_cap_usd)})` : formatCurrency(token.market_cap_usd)} />}
          {isKrc721 ? <MetricTile label="Supply" value={formatInteger(token.total_supply)} /> : <MetricTile label="Holders" value={formatCompact(token.holders)} />}
        </div>
      </div>

      {flaggedDagas ? (
        <div className="mb-6 rounded-md border border-red-500/60 bg-red-500/10 px-4 py-3 text-sm font-bold text-red-300 shadow-[0_0_24px_rgba(239,68,68,0.16)]">
          100% dev minted airdrop token. Metrics have been reported to be not real.
        </div>
      ) : null}

      {token.deployed_at || token.mint_percent !== undefined && token.mint_percent !== null || !isL2 && !isKrc721 && token.total_supply !== undefined && token.total_supply !== null || !isL2 && !isKrc721 && token.burned_supply !== undefined && token.burned_supply !== null ? (
        <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {token.deployed_at ? (
            <MetricTile label="Deployed" value={`${formatDateTime(token.deployed_at)} (${formatAgeSince(token.deployed_at)})`} />
          ) : null}
          {token.mint_percent !== undefined && token.mint_percent !== null ? (
            <MetricTile label="Mint Status" value={`${formatPlainPercent(token.mint_percent)} minted`} tone="primary" />
          ) : null}
          {!isL2 && !isKrc721 && token.total_supply !== undefined && token.total_supply !== null ? (
            <MetricTile label="Max Supply" value={formatTokenAmount(token.total_supply)} />
          ) : null}
          {!isL2 && !isKrc721 && token.burned_supply !== undefined && token.burned_supply !== null ? (
            <MetricTile label="Burned" value={`${formatTokenAmount(token.burned_supply)}${burnedPercent !== null ? ` (${formatPlainPercent(burnedPercent)})` : ""}`} />
          ) : null}
        </div>
      ) : null}

      {isKrc721&&token?<NftGallery ticker={token.symbol}/>:null}
      <div className="mb-5 flex flex-wrap gap-2">
        {visibleTabs.map((item) => {
          const Icon = item.icon;
          return (
            <button key={item.id} onClick={() => setTab(item.id)} className={["focus-ring inline-flex h-10 items-center gap-2 rounded-md border px-3 text-sm font-bold", tab === item.id ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary shadow-kaspa" : "border-kaspa-border bg-kaspa-card text-kaspa-muted hover:text-kaspa-primary"].join(" ")}>
              <Icon className="h-4 w-4" aria-hidden="true" />{item.label}
            </button>
          );
        })}
      </div>


      {tab === "overview" && !isKrc721 ? (
        <div className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="text-sm text-kaspa-muted">{range} price in KAS</div>
            <div className="flex gap-2">
              {(["24h", "7d", "30d"] as ChartRange[]).map((item) => (
                <button key={item} onClick={() => setRange(item)} className={["focus-ring h-9 rounded-md border px-3 text-sm font-bold", range === item ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border bg-kaspa-card text-kaspa-muted"].join(" ")}>
                  {item}
                </button>
              ))}
            </div>
          </div>
          <PriceChart points={collections.chart.data?.points || []} unit="KAS" changeOverride={priceChangeForRange(token, range)} />
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {isL2 ? <MetricTile label="Liquidity" value={formatCurrency(token.dex_liquidity)} /> : null}
            {isKrc721 ? <MetricTile label="24h Volume" value={formatKasVolume(token.volume_24h_kas)} /> : null}
            {isKrc721 ? <MetricTile label="7d Volume" value={formatKasVolume(token.volume_7d_kas)} /> : null}
            {!isL2 ? <MetricTile label="Transfers" value={formatCompact(token.transfers)} /> : null}
            <MetricTile label="24h Volume" value={formatCurrency(token.volume_24h_usd)} />
            <MetricTile label="7d Volume" value={formatCurrencyWindow(token.volume_7d_usd, hasVolumeWindow(token, "7d"))} />
            <MetricTile label="30d Volume" value={formatCurrencyWindow(token.volume_30d_usd, hasVolumeWindow(token, "30d"))} />
          </div>
        </div>
      ) : null}

      {tab === "holders" && !isKrc721 ? <HolderTable holders={collections.holders.data?.holders || []} tokenId={token.id} /> : null}

      {tab === "market" ? <MarketPanel markets={token.markets || []} /> : null}

      {tab === "transactions" && !isKrc721 ? (
        <div className="space-y-4">
          {!isL2 ? (
            <div className="flex flex-wrap gap-2">
              {([undefined, "transfer", "buy", "list", "mint"] as Array<TransactionType | undefined>).map((item) => (
                <button key={item || "all"} onClick={() => setTxType(item)} className={["focus-ring h-9 rounded-md border px-3 text-sm font-bold capitalize", txType === item ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border bg-kaspa-card text-kaspa-muted"].join(" ")}>
                  {item || "all"}
                </button>
              ))}
            </div>
          ) : null}
          <TransactionPanel token={token} type={isL2 ? undefined : txType} emptyMessage={txType === "mint" ? mintEmptyMessage(token.premint_percent) : undefined} />
        </div>
      ) : null}

      {tab === "analytics" && !isKrc721 ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <MetricTile label="24h Volume" value={formatCurrency(token.volume_24h_usd)} />
          <MetricTile label="7d Volume" value={formatCurrencyWindow(token.volume_7d_usd, hasVolumeWindow(token, "7d"))} />
          <MetricTile label="30d Volume" value={formatCurrencyWindow(token.volume_30d_usd, hasVolumeWindow(token, "30d"))} />
          {isL2 ? <MetricTile label="DEX Depth" value={formatCurrency(token.dex_liquidity)} /> : <MetricTile label="Transfers" value={formatCompact(token.transfers)} />}
        </div>
      ) : null}

      {tab === "web" && !isL2 && !isKrc721 ? <WebSocialsPanel token={token} /> : null}
      {tab === "converter" && !isKrc721 ? <PriceConverterPanel token={token} /> : null}
    </section>
  );
}

interface L2BridgeMarket {
  tokenId: string;
  network: string;
  chain: "kasplex" | "igra";
  contractAddress: string;
  marketNames: string[];
}

function bridgedL2Markets(token: Token): L2BridgeMarket[] {
  if (token.layer !== "KRC20") {
    return [];
  }
  const byKey = new Map<string, L2BridgeMarket>();
  for (const market of token.markets || []) {
    if (market.type !== "DEX" || !market.contract_address || !market.network) {
      continue;
    }
    const chain = market.network.toLowerCase().includes("igra") ? "igra" : market.network.toLowerCase().includes("kasplex") ? "kasplex" : null;
    if (!chain) {
      continue;
    }
    const contractAddress = market.contract_address;
    const key = `${chain}:${contractAddress.toLowerCase()}`;
    const existing = byKey.get(key);
    if (existing) {
      if (!existing.marketNames.includes(market.name)) {
        existing.marketNames.push(market.name);
      }
      continue;
    }
    byKey.set(key, {
      tokenId: `l2-${chain}-${contractAddress.toLowerCase()}`,
      network: market.network,
      chain,
      contractAddress,
      marketNames: [market.name]
    });
  }
  return [...byKey.values()];
}

function L2BridgePanel({ bridges }: { bridges: L2BridgeMarket[] }) {
  const sortedBridges = [...bridges].sort((a, b) => a.chain.localeCompare(b.chain));
  const [activeTokenId, setActiveTokenId] = useState(sortedBridges[0]?.tokenId || "");
  const [activeView, setActiveView] = useState<"holders" | "transactions">("holders");
  const activeBridge = sortedBridges.find((bridge) => bridge.tokenId === activeTokenId) || sortedBridges[0];

  if (!activeBridge) {
    return null;
  }

  return (
    <div className="kaspa-panel rounded-md p-5">
      <div className="flex flex-wrap gap-2">
        {sortedBridges.map((bridge) => (
          <button
            key={bridge.tokenId}
            type="button"
            onClick={() => setActiveTokenId(bridge.tokenId)}
            className={["focus-ring h-10 rounded-md border px-4 text-sm font-bold", activeBridge.tokenId === bridge.tokenId ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary shadow-kaspa" : "border-kaspa-border bg-kaspa-card text-kaspa-muted hover:text-kaspa-primary"].join(" ")}
          >
            {bridge.chain === "kasplex" ? "Kasplex" : "Igra"}
          </button>
        ))}
      </div>

      <div className="mt-5 text-xs">
        <span className="mr-3 font-semibold text-kaspa-muted">Contract</span>
        <a href={l2ContractUrl(activeBridge.tokenId, activeBridge.contractAddress) || "#"} target="_blank" rel="noreferrer" className="break-all font-mono text-kaspa-primary hover:underline">{activeBridge.contractAddress}</a>
      </div>

      <div className="mt-5 flex flex-wrap gap-2">
        {(["holders", "transactions"] as const).map((view) => (
          <button
            key={view}
            type="button"
            onClick={() => setActiveView(view)}
            className={["focus-ring h-9 rounded-md border px-3 text-sm font-bold capitalize", activeView === view ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border bg-kaspa-card text-kaspa-muted hover:text-kaspa-primary"].join(" ")}
          >
            {view}
          </button>
        ))}
      </div>

      <div className="mt-5">
        {activeView === "holders" ? <L2BridgeHolders tokenId={activeBridge.tokenId} /> : <L2BridgeTransactions tokenId={activeBridge.tokenId} />}
      </div>
    </div>
  );
}

function L2BridgeHolders({ tokenId }: { tokenId: string }) {
  const [holders, setHolders] = useState<Holder[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    getHolders(tokenId)
      .then((envelope) => {
        if (!active) return;
        setHolders(envelope.data.holders);
        setLoading(false);
      })
      .catch((requestError: Error) => {
        if (!active) return;
        setError(requestError.message);
        setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [tokenId]);

  if (loading) {
    return <div className="h-72 animate-pulse rounded-md border border-kaspa-border bg-kaspa-background" />;
  }

  return (
    <div>
      <div className="mb-3 inline-flex items-center gap-2 text-sm font-bold text-kaspa-text"><Users className="h-4 w-4 text-kaspa-primary" /> L2 Holders</div>
      {error ? <div className="rounded-md border border-red-400/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{error}</div> : <HolderTable holders={holders} tokenId={tokenId} />}
    </div>
  );
}

function L2BridgeTransactions({ tokenId }: { tokenId: string }) {
  const [transactions, setTransactions] = useState<TokenTransaction[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setTransactions([]);
    setNextCursor(null);
    setLoading(true);
    setError(null);
    getTransactions(tokenId)
      .then((envelope) => {
        if (!active) return;
        setTransactions(envelope.data.transactions);
        setNextCursor(envelope.data.next_cursor);
        setLoading(false);
      })
      .catch((requestError: Error) => {
        if (!active) return;
        setError(requestError.message);
        setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [tokenId]);

  function loadMore() {
    if (!nextCursor || loadingMore) {
      return;
    }
    setLoadingMore(true);
    setError(null);
    getTransactions(tokenId, undefined, nextCursor)
      .then((envelope) => {
        setTransactions((current) => mergeTransactions(current, envelope.data.transactions));
        setNextCursor(envelope.data.next_cursor);
      })
      .catch((requestError: Error) => setError(requestError.message))
      .finally(() => setLoadingMore(false));
  }

  if (loading) {
    return <div className="h-72 animate-pulse rounded-md border border-kaspa-border bg-kaspa-background" />;
  }

  return (
    <div className="space-y-3">
      <div className="inline-flex items-center gap-2 text-sm font-bold text-kaspa-text"><List className="h-4 w-4 text-kaspa-primary" /> L2 Transactions</div>
      {error ? <div className="rounded-md border border-red-400/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{error}</div> : <TxTable transactions={transactions} emptyMessage="No L2 transfers found" />}
      {nextCursor ? (
        <div className="flex justify-center">
          <button type="button" onClick={loadMore} disabled={loadingMore} className="focus-ring h-10 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary shadow-kaspa transition hover:bg-kaspa-primary hover:text-kaspa-background disabled:cursor-not-allowed disabled:opacity-40">
            {loadingMore ? "Loading..." : "Load more transactions"}
          </button>
        </div>
      ) : null}
    </div>
  );
}

function TransactionPanel({ token, type, emptyMessage }: { token: Token; type?: TransactionType; emptyMessage?: string }) {
  const [transactions, setTransactions] = useState<TokenTransaction[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setTransactions([]);
    setNextCursor(null);
    setLoading(true);
    setError(null);

    getTransactions(token.id, type)
      .then((envelope) => {
        if (!active) return;
        setTransactions(envelope.data.transactions);
        setNextCursor(envelope.data.next_cursor);
        setLoading(false);
      })
      .catch((requestError: Error) => {
        if (!active) return;
        setError(requestError.message);
        setLoading(false);
      });

    return () => {
      active = false;
    };
  }, [token.id, type]);

  function loadMore() {
    if (!nextCursor || loadingMore) {
      return;
    }
    setLoadingMore(true);
    setError(null);
    getTransactions(token.id, type, nextCursor)
      .then((envelope) => {
        setTransactions((current) => mergeTransactions(current, envelope.data.transactions));
        setNextCursor(envelope.data.next_cursor);
      })
      .catch((requestError: Error) => setError(requestError.message))
      .finally(() => setLoadingMore(false));
  }

  if (loading) {
    return <div className="kaspa-panel h-52 animate-pulse rounded-md" />;
  }

  return (
    <div className="space-y-3">
      {error ? <div className="rounded-md border border-red-400/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{error}</div> : null}
      <TxTable transactions={transactions} emptyMessage={emptyMessage} />
      {nextCursor ? (
        <div className="flex justify-center">
          <button type="button" onClick={loadMore} disabled={loadingMore} className="focus-ring h-10 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary shadow-kaspa transition hover:bg-kaspa-primary hover:text-kaspa-background disabled:cursor-not-allowed disabled:opacity-40">
            {loadingMore ? "Loading..." : "Load more transactions"}
          </button>
        </div>
      ) : null}
    </div>
  );
}

function mergeTransactions(current: TokenTransaction[], next: TokenTransaction[]) {
  const seen = new Set(current.map((transaction) => transaction.id));
  return [...current, ...next.filter((transaction) => !seen.has(transaction.id))];
}

function PremintBadge({ percent }: { percent?: number | null }) {
  if (percent === null || percent === undefined) {
    return null;
  }
  const fullyPreminted = percent >= 99.999;
  const noPremint = percent <= 0;
  const label = noPremint ? "No premint" : fullyPreminted ? "Fully preminted" : formatPremintPercent(percent) + " preminted";
  const className = noPremint
    ? "border-emerald-400/60 bg-emerald-400/10 text-emerald-300"
    : fullyPreminted
      ? "border-red-400/60 bg-red-400/10 text-red-300"
      : "border-amber-400/60 bg-amber-400/10 text-amber-300";
  return <div className={["mt-3 inline-flex rounded-md border px-3 py-1 text-xs font-bold", className].join(" ")}>{label}</div>;
}

function mintEmptyMessage(percent?: number | null) {
  return percent !== null && percent !== undefined && percent >= 99.999
    ? "This token is preminted."
    : "No mints found. Only the latest 3000 KRC20 operations will be scanned.";
}

function formatPremintPercent(percent: number) {
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: percent < 1 ? 2 : 1
  }).format(percent) + "%";
}

function MarketPanel({ markets }: { markets: TokenMarket[] }) {
  if (markets.length === 0) {
    return <EmptyState title="No market data found" body="No configured market source is available for this token." />;
  }

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {markets.map((market) => (
        <div key={market.id} className="kaspa-panel rounded-md p-5">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div className="text-xs font-semibold text-kaspa-muted">{market.type === "DEX" ? "DEX" : "Marketplace"}</div>
              <h2 className="mt-1 text-xl font-bold text-kaspa-text">{market.name}</h2>
              {market.network ? <div className="mt-1 text-sm text-kaspa-muted">{market.network}</div> : null}
            </div>
            <span className={["rounded-md border px-3 py-1 text-xs font-bold", market.source_status === "LIVE" ? "border-kaspa-primary/70 bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border bg-kaspa-bg text-kaspa-muted"].join(" ")}>
              {market.source_status === "TO_CONFIRM" ? "Mapping pending" : market.source_status}
            </span>
          </div>

          <div className="mt-5 grid gap-3 sm:grid-cols-2">
            <MetricTile label="Price" value={formatKas(market.price_kas)} tone={market.price_kas !== null ? "primary" : "muted"} />
            <MetricTile label="USD" value={formatCurrency(market.price_usd)} />
            <MetricTile label="24h Volume" value={formatCurrency(market.volume_24h_usd ?? 0)} />
            {market.volume_7d_available !== false ? <MetricTile label="7d Volume" value={formatCurrency(market.volume_7d_usd ?? 0)} /> : null}
            {market.volume_30d_available !== false ? <MetricTile label="30d Volume" value={formatCurrency(market.volume_30d_usd ?? 0)} /> : null}
            {market.type === "DEX" ? <MetricTile label="Liquidity" value={formatCurrency(market.dex_liquidity)} /> : null}
          </div>

          {market.contract_address ? (
            <div className="mt-4 text-xs">
              <span className="mr-2 font-semibold text-kaspa-muted">Contract</span>
              <span className="break-all font-mono text-kaspa-text">{market.contract_address}</span>
            </div>
          ) : null}

          {market.notes ? <p className="mt-4 text-sm text-kaspa-muted">{market.notes}</p> : null}
        </div>
      ))}
    </div>
  );
}

function WebSocialsPanel({ token }: { token: Token }) {
  const githubUrl = token.layer === "KRC20" && token.symbol.trim().toUpperCase() === "KASBTC"
    ? "https://github.com/KaspaHUB21"
    : undefined;
  const links = [
    { label: "Website", url: token.socials?.website },
    { label: "Twitter", url: token.socials?.twitter },
    { label: "Telegram", url: token.socials?.telegram },
    { label: "Discord", url: token.socials?.discord },
    { label: "GitHub", url: githubUrl }
  ].filter((item): item is { label: string; url: string } => Boolean(item.url));

  if (!token.banner_url && !token.description && links.length === 0) {
    return <EmptyState title="No web or social links found" />;
  }

  return (
    <div className="space-y-5">
      {token.banner_url ? (
        <div className="aspect-[7/3] overflow-hidden rounded-md border border-kaspa-border bg-kaspa-card">
          <img src={token.banner_url} alt={token.name + " banner"} className="h-full w-full object-contain" />
        </div>
      ) : null}

      {token.description ? (
        <div className="kaspa-panel rounded-md p-5">
          <h2 className="text-lg font-bold text-kaspa-text">Description</h2>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-kaspa-muted">{token.description}</p>
        </div>
      ) : null}

      {links.length > 0 ? (
        <div className={["grid gap-3", links.length >= 4 ? "sm:grid-cols-2 lg:grid-cols-4" : "sm:grid-cols-3"].join(" ")}>
          {links.map((link) => (
            <a key={link.label} href={link.url} target="_blank" rel="noreferrer" className="focus-ring rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 py-3 text-center text-sm font-bold text-kaspa-primary shadow-kaspa transition hover:bg-kaspa-primary hover:text-kaspa-background">
              {link.label}
            </a>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function PriceConverterPanel({ token }: { token: Token }) {
  const [balanceInput, setBalanceInput] = useState("1");
  const balance = parseBalance(balanceInput);
  const kasValue = balance !== null && token.price_kas !== null ? balance * token.price_kas : null;
  const usdValue = balance !== null && token.price_usd !== null ? balance * token.price_usd : null;
  const canConvertKas = balance !== null && token.price_kas !== null;
  const canConvertUsd = balance !== null && token.price_usd !== null;

  return (
    <div className="relative overflow-hidden rounded-md border border-kaspa-primary/45 bg-kaspa-card p-4 shadow-kaspa sm:p-5">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-px bg-kaspa-primary" />
      <div className="pointer-events-none absolute right-0 top-0 h-32 w-32 border-l border-kaspa-primary/20 bg-kaspa-primary/10 blur-3xl" />

      <div className="relative flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="text-xs font-bold text-kaspa-primary">Price Converter</div>
          <h2 className="mt-2 break-words text-xl font-bold text-kaspa-text sm:text-2xl">{token.symbol} Balance Value</h2>
        </div>
        <div className="grid w-full grid-cols-1 gap-2 text-xs min-[420px]:grid-cols-2 sm:w-auto sm:min-w-[280px]">
          <div className="min-w-0 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
            <div className="truncate font-semibold text-kaspa-muted">1 {token.symbol}</div>
            <div className="mt-1 break-words font-bold text-kaspa-primary">{formatKas(token.price_kas)}</div>
          </div>
          <div className="min-w-0 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
            <div className="font-semibold text-kaspa-muted">USD</div>
            <div className="mt-1 break-words font-bold text-kaspa-text">{formatCurrency(token.price_usd)}</div>
          </div>
        </div>
      </div>

      <div className="relative mt-6 grid gap-4 lg:grid-cols-[1fr_1.15fr]">
        <label className="block min-w-0 rounded-md border border-kaspa-border bg-kaspa-background p-4">
          <span className="text-xs font-bold text-kaspa-muted">Token balance</span>
          <div className="mt-3 flex min-h-14 min-w-0 items-center gap-3 rounded-md border border-kaspa-primary/30 bg-kaspa-card px-3 focus-within:border-kaspa-primary focus-within:shadow-kaspa sm:px-4">
            <span className="shrink-0 text-sm font-bold text-kaspa-primary">{token.symbol}</span>
            <input
              value={balanceInput}
              onChange={(event) => setBalanceInput(event.target.value)}
              inputMode="decimal"
              className="min-w-0 flex-1 bg-transparent text-right text-xl font-bold text-kaspa-text outline-none sm:text-2xl"
              placeholder="0"
              aria-label={token.symbol + " balance"}
            />
          </div>
        </label>

        <div className="grid min-w-0 gap-4 sm:grid-cols-2">
          <ConverterValue label="Value in KAS" value={canConvertKas ? formatKas(kasValue) : "Currently unavailable"} tone="primary" />
          <ConverterValue label="Value in USD" value={canConvertUsd ? formatCurrency(usdValue) : "Currently unavailable"} />
        </div>
      </div>
    </div>
  );
}

function ConverterValue({ label, value, tone = "default" }: { label: string; value: string; tone?: "primary" | "default" }) {
  return (
    <div className="min-w-0 rounded-md border border-kaspa-border bg-kaspa-background p-4">
      <div className="text-xs font-bold text-kaspa-muted">{label}</div>
      <div className={["mt-3 break-words text-xl font-bold sm:text-2xl", tone === "primary" ? "text-kaspa-primary" : "text-kaspa-text"].join(" ")}>{value}</div>
    </div>
  );
}

function parseBalance(value: string) {
  const normalized = normalizeNumericInput(value);
  if (!normalized) {
    return 0;
  }
  const parsed = Number(normalized);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function normalizeNumericInput(value: string) {
  const compact = value.trim().replace(/\s+/g, "");
  if (!compact) {
    return "";
  }
  const hasComma = compact.includes(",");
  const hasDot = compact.includes(".");
  if (hasComma && hasDot) {
    const lastComma = compact.lastIndexOf(",");
    const lastDot = compact.lastIndexOf(".");
    const decimalSeparator = lastComma > lastDot ? "," : ".";
    const thousandsSeparator = decimalSeparator === "," ? "." : ",";
    return compact.split(thousandsSeparator).join("").replace(decimalSeparator, ".");
  }
  if (hasComma) {
    const parts = compact.split(",");
    const thousandsFormat = parts.length > 1 && parts.slice(1).every((part) => /^\d{3}$/.test(part));
    return thousandsFormat ? parts.join("") : compact.replace(",", ".");
  }
  if (hasDot) {
    const parts = compact.split(".");
    const thousandsFormat = parts.length > 1 && parts.slice(1).every((part) => /^\d{3}$/.test(part));
    return thousandsFormat ? parts.join("") : compact;
  }
  return compact;
}

function l2ContractUrl(tokenId: string, address: string) {
  if (tokenId.startsWith("l2-kasplex-")) {
    return "https://explorer.kasplex.org/token/" + encodeURIComponent(address);
  }
  if (tokenId.startsWith("l2-igra-")) {
    return "https://explorer.igralabs.com/token/" + encodeURIComponent(address);
  }
  return null;
}

function isDagasWarningToken(token: Token) {
  return token.layer === "KRC20" && token.symbol.trim().toUpperCase() === "DAGAS";
}

