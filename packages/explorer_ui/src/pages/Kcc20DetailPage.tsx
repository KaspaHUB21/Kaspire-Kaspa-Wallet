import { useMemo, useState, type ReactNode } from "react";
import {displayableKcc20} from '../utils/kcc20Visibility';
import {FavoriteButton} from '../components/FavoriteButton';
import { Link, useParams } from "react-router-dom";
import { ArrowLeft, DatabaseZap, List, Users } from "../components/icons";
import { EmptyState } from "../components/EmptyState";
import { MetricTile } from "../components/MetricTile";
import { PriceChart } from "../components/PriceChart";
import { TokenLogo } from "../components/TokenLogo";
import { useKcc20DexToken, useKcc20Token, useKcc20TransactionOwners, useTokenChart } from "../services/tokens";
import type { ChartRange, Kcc20Balance, Kcc20DexInterval, Kcc20DexTrade, Kcc20Event, Kcc20OwnerChange, Kcc20Token, Kcc20TransactionOwners } from "../types/token";
import { formatCurrency, formatDateTime, formatInteger, formatKas, formatKcc20Amount } from "../utils/format";
import { kcc20TradeLabels, kcc20TransactionLabel, kcc20EventAmount, type Kcc20TransactionLabel } from "../utils/kcc20Transactions";

type DetailTab = "holders" | "transactions" | "dex-trades" | "state";
const eventPageSize = 25;

export function Kcc20DetailPage() {
  const { covenantId } = useParams();
  const state = useKcc20Token(covenantId);
  const [tab, setTab] = useState<DetailTab>("holders");
  const [eventLimit, setEventLimit] = useState(eventPageSize);
  const [dexInterval] = useState<Kcc20DexInterval>("1h");
  const detail = state.data;
  const dexState = useKcc20DexToken(covenantId, dexInterval);
  const tradeLabels = useMemo(() => kcc20TradeLabels(dexState.data?.trades || []), [dexState.data?.trades]);
  const orderedEvents = useMemo(() => [...(detail?.events || [])].sort((a, b) => b.accepting_daa - a.accepting_daa || (b.tx_index || 0) - (a.tx_index || 0)), [detail?.events]);
  const visibleEvents = orderedEvents.slice(0, eventLimit);
  const ownerState = useKcc20TransactionOwners(covenantId, visibleEvents.map((event) => event.txid), tab === "transactions");

  if (state.loading) return <div className="kaspa-panel h-96 animate-pulse rounded-md" />;
  if (state.error || !detail) return <EmptyState title="KCC20 token not found" body={state.error || undefined} />;

  const token = detail.token;
  if(!displayableKcc20(token))return <EmptyState title="Token not listed in Kaspire" body="This is a retired test issuance or its identity is not published. Wallet data is unchanged."/>;
  const isKasvio = ["kasvio","kasseal","kasforge","kforge","kron"].includes(token.fields.indexer_source);
  const ticker = token.claimed_ticker || token.fields.tick || token.fields.ticker || "";
  const title = ticker || token.claimed_name || token.name;
  const subtitle = token.claimed_name && token.claimed_name !== title ? token.claimed_name : token.name !== title ? token.name : null;
  const ownerDetails = new Map((ownerState.data?.transactions || []).map((item) => [item.txid, item]));
  const detailTabs: Array<{ id: DetailTab; label: string; icon: typeof Users }> = [
    { id: "holders", label: "Holders", icon: Users },
    { id: "transactions", label: "Transactions", icon: List },
    ...(dexState.data?.market ? [{ id: "dex-trades" as const, label: "Recent DEX Trades", icon: List }] : []),
    { id: "state", label: "On-chain State", icon: DatabaseZap }
  ];

  return (
    <section>
      <Link to="/kcc20" className="focus-ring mb-5 inline-flex items-center gap-2 rounded-md text-sm font-semibold text-kaspa-muted hover:text-kaspa-primary"><ArrowLeft className="h-4 w-4" /> Back to KCC20</Link>

      <div className="kaspa-panel mb-6 flex flex-col gap-5 rounded-md p-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="flex min-w-0 items-start gap-4">
          <TokenLogo src={token.image_url || undefined} symbol={title} size="lg" />
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-3">
              <h1 className="truncate text-3xl font-bold text-kaspa-text">{title}</h1>
            </div>
            {subtitle ? <div className="mt-1 text-sm text-kaspa-muted">{subtitle}</div> : null}
            {token.metadata_source === "genesis_payload" ? <div className="mt-2 inline-flex rounded-sm border border-kaspa-primary/40 bg-kaspa-primary/10 px-2 py-1 text-[11px] font-semibold text-kaspa-primary">Named on chain</div> : null}
            <div className="mt-3 max-w-3xl break-all font-mono text-xs leading-relaxed text-kaspa-muted">{token.covenant_id}</div>
          </div>
        </div>
        <FavoriteButton tokenId={'kcc20-'+token.covenant_id} compact/>
      </div>

      {dexState.data?.market ? <Kcc20DexMarketSection state={dexState.data} /> : null}

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <MetricTile label="Live Supply" value={formatKcc20Amount(token.supply, token.decimals)} tone="primary" />
        <MetricTile label="Holders" value={formatInteger(token.holders)} />
        <MetricTile label="Actions" value={token.fields.transaction_data_available==="false"?"Not indexed":formatInteger(token.action_count)} />
        <MetricTile label="Burned" value={formatKcc20Amount(token.burned, token.decimals)} />
        <MetricTile label={token.live_value_sompi === null ? "Standard" : "Locked KAS"} value={token.live_value_sompi === null ? standardLabel(token.standard) : formatKas(token.live_value_sompi / 1e8)} />
      </div>

      <div className="kaspa-panel mb-6 rounded-md p-4">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-3">
            <DatabaseZap className="mt-0.5 h-5 w-5 shrink-0 text-kaspa-primary" />
            <div>
              <div className="font-bold text-kaspa-text">On-chain validation</div>
              <div className="mt-1 text-sm text-kaspa-muted">{isKasvio ? <>{detail.validation.checked} indexed transactions · {detail.validation.unresolved_cells} unresolved cells</> : <>{detail.validation.checked} transitions checked · {detail.validation.unresolved_cells} unresolved cells · derived at DAA {formatInteger(detail.validation.derived_at_daa)}</>}</div>
              {detail.validation.reason ? <div className="mt-2 text-sm text-kaspa-primary">{detail.validation.reason}</div> : null}
            </div>
          </div>
          <div className="text-xs text-kaspa-muted">{isKasvio ? detail.tip_at_ms ? <>Kasvio snapshot {formatDateTime(new Date(detail.tip_at_ms).toISOString())}</> : <>{token.fields.market_venue || "Kasseal"} indexer</> : <>Mainnet tip {formatInteger(detail.tip_daa)}</>}</div>
        </div>
      </div>

      <div className="mb-5 flex flex-wrap gap-2">
        {detailTabs.map((item) => {
          const Icon = item.icon;
          return <button key={item.id} onClick={() => setTab(item.id)} className={["focus-ring inline-flex h-10 items-center gap-2 rounded-md border px-3 text-sm font-bold", tab === item.id ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary shadow-kaspa" : "border-kaspa-border bg-kaspa-card text-kaspa-muted hover:text-kaspa-primary"].join(" ")}><Icon className="h-4 w-4" />{item.label}</button>;
        })}
      </div>

      {tab === "holders" ? <Kcc20Holders token={token} balances={detail.balances} /> : null}
      {tab === "transactions" ? (
        <div className="space-y-4">
          <Kcc20Events events={visibleEvents} token={token} tipDaa={detail.tip_daa} tipAtMs={detail.tip_at_ms} ownerDetails={ownerDetails} ownerLoading={ownerState.loading} tradeLabels={tradeLabels} />
          {eventLimit < detail.events.length ? <div className="flex justify-center"><button onClick={() => setEventLimit((value) => value + eventPageSize)} className="focus-ring h-10 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary">Load more transactions</button></div> : null}
        </div>
      ) : null}
      {tab === "dex-trades" ? <Kcc20DexTrades trades={dexState.data?.trades || []} /> : null}
      {tab === "state" ? <Kcc20State token={token} /> : null}
    </section>
  );
}

function Kcc20DexMarketSection({ state }: { state: NonNullable<ReturnType<typeof useKcc20DexToken>["data"]> }) {
  const [range,setRange]=useState<ChartRange>("30d");
  const chart=useTokenChart("kcc20-"+(state.market?.covenant_id||""),range);
  const market = state.market;
  if (!market) {
    return null;
  }
  const chartPoints = chart.data?.points || state.candles.map((candle) => ({
    time: candle.time,
    price_kas: candle.close,
    price_usd: null
  }));
  return (
    <div className="mb-6">
      <div className="mb-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <MetricTile label="Price" value={<MarketValue usd={market.price_usd} kas={market.price_kas} />} tone="primary" />
        <MetricTile label="Market Cap" value={<MarketValue usd={market.market_cap_usd} kas={market.market_cap_kas} />} />
        <MetricTile label="24h Volume" value={<MarketValue usd={market.volume_24h_usd} kas={market.volume_24h_kas} />} />
        <MetricTile label={market.liquidity_label || (market.venue === "Kasseal" && !market.graduated ? "Curve reserve" : "TVL")} value={<MarketValue usd={market.tvl_usd} kas={market.tvl_kas} />} />
        <MetricTile label="Market" value={market.graduated ? "AMM Pool" : "Bonding Curve"} />
      </div>
      <div className="kaspa-panel mb-3 flex flex-wrap items-center justify-between gap-3 rounded-md p-3">
        <h2 className="text-lg font-bold text-kaspa-text">{market.venue || "KaspaRocket"} chart</h2>
        <div className="inline-flex rounded-md border border-kaspa-border bg-kaspa-card p-1">
          {(["24h", "7d", "30d", "1y", "all"] as ChartRange[]).map((value) => <button key={value} onClick={() => setRange(value)} className={["focus-ring rounded-sm px-3 py-1.5 text-xs font-bold", range === value ? "bg-kaspa-primary/10 text-kaspa-primary" : "text-kaspa-muted hover:text-kaspa-primary"].join(" ")}>{value === "all" ? "All time" : value}</button>)}
        </div>
      </div>
      <PriceChart points={chartPoints} unit="KAS" changeOverride={range==="24h"?market.change_24h_percent:null} />
      {chartPoints.length>0 ? <div className="kaspa-panel mt-2 rounded-md p-3 text-xs text-kaspa-muted">Available history from {formatDateTime(new Date(chartPoints[0].time*1000).toISOString())}. Missing periods are not estimated.</div> : null}
    </div>
  );
}

function MarketValue({ usd, kas }: { usd?: number | null; kas: number | null }) {
  return <span className="leading-tight"><span className="block">{formatCurrency(usd)}</span><span className="mt-1 block text-xs font-semibold text-kaspa-muted">{formatKas(kas)}</span></span>;
}

function Kcc20DexTrades({ trades }: { trades: Kcc20DexTrade[] }) {
  if (trades.length === 0) {
    return <EmptyState title="No DEX trades found" />;
  }
  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2" data-kcc20-mobile="dex-trades">
        {trades.map(trade=><article key={trade.txid} className="min-w-0 rounded-md border border-kaspa-border p-4">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3"><Kcc20TypeBadge label={trade.side}/><time className="text-xs text-kaspa-muted">{formatDateTime(new Date(trade.time*1000).toISOString())}</time></div>
          <div className="grid min-w-0 grid-cols-2 gap-3"><Kcc20CardFact label="Price">{formatKas(trade.price_kas)}</Kcc20CardFact><Kcc20CardFact label="Volume">{formatKas(trade.volume_kas)}</Kcc20CardFact></div>
          <Kcc20CardTransaction txid={trade.txid}/>
        </article>)}
      </div>
    </div>
  );
}

function Kcc20Holders({ token, balances }: { token: Kcc20Token; balances: Kcc20Balance[] }) {
  if(token.fields.holder_data_available==="false") return <EmptyState title="Holder list temporarily unavailable" />;
  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2" data-kcc20-mobile="holders">
        {balances.map((balance,index)=><article className="min-w-0 rounded-md border border-kaspa-border p-4" key={balance.owner}>
          <div className="text-sm font-bold text-kaspa-muted">#{index+1}</div>
          <div className="my-3 min-w-0"><Kcc20OwnerLink owner={balance.owner} address={balance.owner_address}/></div>
          <div className="grid min-w-0 grid-cols-2 gap-3"><Kcc20CardFact label="Balance" wide>{formatKcc20Amount(balance.balance,token.decimals)}</Kcc20CardFact><Kcc20CardFact label="Supply">{token.supply>0?(balance.balance/token.supply*100).toFixed(4)+'%':'n/a'}</Kcc20CardFact><Kcc20CardFact label="Cells">{formatInteger(balance.cells)}</Kcc20CardFact></div>
        </article>)}
      </div>
    </div>
  );
}

function Kcc20Events({ events, token, tipDaa, tipAtMs, ownerDetails, ownerLoading, tradeLabels }: { events: Kcc20Event[]; token: Kcc20Token; tipDaa: number | null; tipAtMs: number | null; ownerDetails: Map<string, Kcc20TransactionOwners>; ownerLoading: boolean; tradeLabels: ReadonlyMap<string, Kcc20TransactionLabel> }) {
  if (events.length === 0) return <EmptyState title={token.fields.transaction_data_available==="false"?"On-chain transaction history is not indexed yet":"No KCC20 transactions found"} />;
  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2" data-kcc20-mobile="transactions">
        {events.map(event=>{const changes=ownerDetails.get(event.txid)?.owner_changes||[],label=kcc20TransactionLabel(event,tradeLabels);return <article key={`${event.txid}-${event.delta_idx??0}`} className="min-w-0 rounded-md border border-kaspa-border p-4">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3"><Kcc20TypeBadge label={label}/><span className="kcc20-card-number min-w-0 max-w-full text-sm font-bold">{formatKcc20Amount(kcc20EventAmount(event,changes),token.decimals)}</span></div>
          <div className="grid min-w-0 gap-3"><Kcc20CardFact label="From"><Kcc20OwnerChanges changes={changes} direction="from" loading={ownerLoading} compact={false}/></Kcc20CardFact><Kcc20CardFact label="To"><Kcc20OwnerChanges changes={changes} direction="to" loading={ownerLoading} compact={false}/></Kcc20CardFact><Kcc20CardFact label="Accepted"><div>DAA {formatInteger(event.accepting_daa)}</div><time className="mt-1 block text-xs text-kaspa-muted">{eventTime(event,tipDaa,tipAtMs)}</time></Kcc20CardFact></div>
          <Kcc20CardTransaction txid={event.txid}/>
        </article>})}
      </div>
    </div>
  );
}

function Kcc20OwnerChanges({ changes, direction, loading, compact=true }: { changes: Kcc20OwnerChange[]; direction: "from" | "to"; loading: boolean; compact?:boolean }) {
  const matching = changes.filter((change) => change.direction === direction);
  if (matching.length === 0) return <span className="font-mono text-xs text-kaspa-muted">{loading ? "Loading…" : "n/a"}</span>;
  return <div className="space-y-1">{matching.map((change, index) => <Kcc20OwnerLink key={`${change.owner}-${index}`} owner={change.owner} address={change.owner_address} compact={compact} />)}</div>;
}

function Kcc20OwnerLink({ owner, address, fallback = "Unknown", compact = false }: { owner: string | null; address: string | null; fallback?: string; compact?: boolean }) {
  if (!owner) {
    return <span className="font-mono text-xs text-kaspa-muted">{fallback}</span>;
  }
  if (!address) {
    return <span className="block text-xs font-semibold text-kaspa-muted" title={`Covenant owner: ${owner}`}>Covenant owner{!compact?<span className="mt-1 block break-all font-mono font-normal">{owner}</span>:null}</span>;
  }
  return (
    <Link
      to={`/wallet/krc20/${encodeURIComponent(address)}`}
      title={`${owner}\n${address}`}
      className={["focus-ring block font-mono text-xs text-kaspa-primary hover:underline", compact ? "truncate" : "break-all"].join(" ")}
    >
      {address}
    </Link>
  );
}

function Kcc20CardFact({label,wide=false,children}:{label:string;wide?:boolean;children:ReactNode}) {
  return <div className={'min-w-0 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2'+(wide?' col-span-2':'')}><div className="mb-1 text-[10px] font-bold text-kaspa-muted">{label}</div><div className="kcc20-card-number min-w-0 text-sm font-bold text-kaspa-text">{children}</div></div>;
}
function Kcc20TypeBadge({label}:{label:string}) {const side=label.toLowerCase();return <span className={'shrink-0 rounded-sm border px-2 py-1 text-xs font-semibold capitalize '+(side==='buy'?'kcc20-buy border-green-500/50':side==='sell'?'kcc20-sell border-red-500/50':'border-kaspa-border text-kaspa-primary')}>{label}</span>;}
function Kcc20CardTransaction({txid}:{txid:string}) {return <div className="mt-3 min-w-0 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2"><div className="mb-1 text-[10px] font-bold text-kaspa-muted">Transaction</div><Link to={'/tx/'+txid} className="block break-all font-mono text-[11px] leading-relaxed text-kaspa-primary">{txid}</Link></div>;}

function Kcc20State({ token }: { token: Kcc20Token }) {
  const rows = useMemo(() => Object.entries(token.fields), [token.fields]);
  return (
    <div className="kaspa-panel rounded-md p-5">
      <div className="mb-4"><h2 className="text-lg font-bold text-kaspa-text">Decoded current state</h2><p className="mt-1 text-sm text-kaspa-muted">Values are shown exactly as exposed by the Mainnet covenant indexer.</p></div>
      <div className="divide-y divide-kaspa-border rounded-md border border-kaspa-border">
        {rows.map(([key, value]) => <div key={key} className="grid gap-2 px-4 py-3 sm:grid-cols-[180px_minmax(0,1fr)]"><div className="text-sm font-semibold text-kaspa-muted">{humanField(key)}</div><div className="break-all font-mono text-xs text-kaspa-text">{value}</div></div>)}
      </div>
    </div>
  );
}

function standardLabel(standard: string | null) {
  return standard === "legacy-kcc20" ? "Legacy KCC20" : standard || "n/a";
}

function shortId(value: string) {
  return value.length > 16 ? `${value.slice(0, 8)}...${value.slice(-6)}` : value;
}

function humanField(value: string) {
  return value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
}

function estimatedTime(daa: number, tipDaa: number | null, tipAtMs: number | null) {
  if (tipDaa === null || tipAtMs === null || daa > tipDaa) return "n/a";
  return `~${formatDateTime(new Date(tipAtMs - (tipDaa - daa) * 100).toISOString())}`;
}

function eventTime(event: Kcc20Event, tipDaa: number | null, tipAtMs: number | null) {
  if (event.accepted_at_ms != null) return formatDateTime(new Date(event.accepted_at_ms).toISOString());
  return estimatedTime(event.accepting_daa, tipDaa, tipAtMs);
}

