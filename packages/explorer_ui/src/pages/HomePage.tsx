import {useDotk,type DotkList} from '../services/dotk';
import { Link, useNavigate } from "react-router-dom";
import {useRead} from '../nativeApi';
import {CovenantIdentity} from '../components/CovenantIdentity';
import {displayableKcc20,retiredKcc20} from '../utils/kcc20Visibility';
import { DirectionalPercent } from "../components/DirectionalPercent";
import { Search } from "../components/icons";
import { LoadingState } from "../components/LoadingState";
import { HomeBanners } from "../components/HomeBanners";
import { MetricTile } from "../components/MetricTile";
import { TokenLogo } from "../components/TokenLogo";
import { ThemeSwitcher } from "../components/ThemeSwitcher";
import { VolumeValue } from "../components/VolumeValue";
import { useHomeSearchIndex, useHomeSummary, useKaspaStats, useKnsSearch } from "../services/tokens";
import { useWalletLabels, type WalletLabelMatch } from "../services/walletLabels";
import type { HomeSummaryToken, KaspaHashratePoint, KaspaStats, KaspaStatsPoint, KaspaStatsRange, KnsDomain } from "../types/token";
import { formatCurrency, formatKas, formatKasVolume, formatUnixDateTime } from "../utils/format";
import { useEffect, useMemo, useState, type PointerEvent } from "react";
import { chartScale, axisUnit, axisNumber } from '../utils/chartScale';

export function HomePage() {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [kaspaStatsRange, setKaspaStatsRange] = useState<KaspaStatsRange>("24h");
  const [hashrateRange,setHashrateRange]=useState<KaspaStatsRange>('24h');
  const isTxId=/^[a-f0-9]{64}$/i.test(query.trim());
  const navigate=useNavigate();
  const covenantQuery=isTxId?query.trim().toLowerCase():'';
  const covenantLookup=useRead(covenantQuery?'https://kaspatoken.kaslab.space/api/kcc20/token/'+covenantQuery:null);
  const { labelSearchMatches } = useWalletLabels();
  const searchEnabled = query.trim().length > 0;
  const searchIndex = useHomeSearchIndex(searchEnabled);
  const knsSearchEnabled = !/^[a-f0-9]{64}$/i.test(debouncedQuery.trim()) && debouncedQuery.trim().length > 0 && !debouncedQuery.trim().startsWith("kaspa:") && !debouncedQuery.trim().startsWith("0x") && !debouncedQuery.trim().toLowerCase().endsWith(".igra");
  const knsSearch = useKnsSearch(debouncedQuery, knsSearchEnabled);
  const dotkEnabled=knsSearchEnabled&&/^[a-z0-9-]+(?:\.k)?$/i.test(debouncedQuery.trim());
  const dotk=useDotk<DotkList>(dotkEnabled?'names?'+new URLSearchParams({query:debouncedQuery,page:'1'}):null);
  const kaspaStats = useKaspaStats(kaspaStatsRange);
  const hashrateStats=useKaspaStats(hashrateRange);
  const loading = kaspaStats.loading || hashrateStats.loading;
  const allTokens = (searchIndex.data?.tokens || []).filter(t=>t.layer!=="L2"&&(t.layer!=="KCC20"||displayableKcc20(t)));
  const covenantMatch=covenantQuery?allTokens.find(token=>token.layer==='KCC20'&&token.id.toLowerCase()==='kcc20-'+covenantQuery):undefined;
  const recognizedCovenant=covenantLookup.data?.data?.token?.covenant_id===covenantQuery?covenantLookup.data.data.token:null;
  const hiddenCovenant=retiredKcc20.has(covenantQuery)||!!recognizedCovenant&&!displayableKcc20(recognizedCovenant);
  const resolvedCovenant=!hiddenCovenant&&(covenantMatch||recognizedCovenant)?covenantQuery:null;
  useEffect(()=>{if(resolvedCovenant)navigate('/kcc20/'+resolvedCovenant);},[resolvedCovenant,navigate]);
  const results = useMemo(() => searchResults(allTokens, query), [allTokens, query]);
  const walletLinks = uniqueSearchLinks([
    ...labelWalletResults(labelSearchMatches(query)),
    ...knsDomainResults(knsSearch.data?.domains || []),
    ...(dotk.data?.names??[]).slice(0,12).map(n=>({href:'/dotk/'+encodeURIComponent(n.name),title:n.name,subtitle:'dotK · '+(n.owner??'Registered name')})),
    ...(isTxId&&!resolvedCovenant&&!hiddenCovenant?[{href:'/tx/'+query.trim().toLowerCase(),title:'View Kaspa transaction',subtitle:query.trim()}]:[]),
    ...walletResults(query)
  ]);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  return (
    <section className="space-y-8">
      <div>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="min-w-0 text-2xl font-black text-kaspa-text">Explore the Kaspa Network</h1>
          
        </div>
        <label className="focus-within:shadow-kaspa mt-5 flex min-h-12 items-center gap-3 rounded-md border border-kaspa-border bg-kaspa-card px-4 transition focus-within:border-kaspa-primary">
          <Search className="h-5 w-5 shrink-0 text-kaspa-muted" />
          <input value={query} onChange={(event) => setQuery(event.target.value)} className="min-w-0 flex-1 bg-transparent text-base font-semibold text-kaspa-text outline-none placeholder:text-kaspa-muted" placeholder="Search TX ID, wallet, ticker, or name" />
        </label>
        
      </div>

      {loading ? <LoadingState /> : null}
      {query.trim() ? (
        <div className="grid gap-3 md:grid-cols-2">
          {hiddenCovenant?<div className="kaspa-panel rounded-md p-4 text-sm">This legacy test token or unidentified covenant is not listed in Kaspire.</div>:null}
          {results.map((token) => <TokenResult key={token.id} token={token} />)}
          {walletLinks.map((item) => <SearchLink key={item.href} href={item.href} title={item.title} subtitle={item.subtitle} />)}
          {searchIndex.loading || knsSearch.loading && knsSearchEnabled ? <div className="kaspa-panel rounded-md p-5 text-sm text-kaspa-muted">Searching...</div> : null}
          {!isTxId&&(searchIndex.error || (knsSearchEnabled && knsSearch.error) || (dotkEnabled&&dotk.error)) ? <div role="status" className="kaspa-panel rounded-md p-4">{dotk.error?'dotK name search is temporarily unavailable. Known token and KNS results remain available.':'Some search sources are temporarily unavailable. Known results remain available.'}</div> : null}
          {!searchIndex.loading && !searchIndex.error && (!knsSearchEnabled || (!knsSearch.loading && !knsSearch.error && !dotk.loading && !dotk.error)) && results.length === 0 && walletLinks.length === 0 ? <div className="kaspa-panel rounded-md p-5 text-sm text-kaspa-muted">No matches found</div> : null}
        </div>
      ) : null}

      <MetricTile label="Kaspa Market Cap" value={formatCurrency(kaspaStats.data?.market_cap_usd)}/>
      <KaspaStatsPanel mode="price" stats={kaspaStats.data} loading={kaspaStats.loading} range={kaspaStatsRange} onRange={setKaspaStatsRange} />
      <KaspaStatsPanel mode="hashrate" stats={hashrateStats.data} loading={hashrateStats.loading} range={hashrateRange} onRange={setHashrateRange} />
      {hashrateStats.error?<p role="alert">Hashrate data temporarily unavailable.</p>:null}
      {kaspaStats.error?<p role="alert">Kaspa stats unavailable: {kaspaStats.error}</p>:null}
    </section>
  );
}

function TokenResult({ token, value, showLayer = true }: { token: HomeSummaryToken; value?: string; showLayer?: boolean }) {
  const covenantId = token.layer === 'KCC20' ? /^kcc20-([a-f0-9]{64})$/i.exec(token.id)?.[1] : undefined;
  const numericValue = token.price_change_24h_percent;
  const directionalStyle = typeof numericValue === "number" && Number.isFinite(numericValue) && value?.includes("%")
    ? { color: numericValue > 0 ? "#00FF00" : numericValue < 0 ? "#FF0000" : undefined }
    : undefined;
  return (
    <Link to={token.layer === "KCC20" ? `/kcc20/${encodeURIComponent(token.id.replace(/^kcc20-/, ""))}` : `/token/${encodeURIComponent(token.id)}`} className="kaspa-panel flex items-center gap-3 rounded-md p-4 transition hover:border-kaspa-primary/80">
      <TokenLogo src={token.image_url} symbol={token.symbol} size="sm" />
      <div className="min-w-0 flex-1">
        <div className="truncate font-bold text-kaspa-text">{token.symbol}</div>
        {token.name && token.name.toLowerCase() !== token.symbol.toLowerCase() ? <div className="mt-0.5 truncate text-xs text-kaspa-muted">{token.name}</div> : null}
        <CovenantIdentity value={covenantId}/>
      </div>
      {showLayer ? <div className="shrink-0 rounded-sm border border-kaspa-border px-2 py-0.5 text-[10px] font-bold text-kaspa-muted">{token.layer}</div> : null}
      {value ? (
        <div className="shrink-0 text-right text-sm font-normal text-kaspa-primary" style={directionalStyle}>
          {typeof numericValue === "number" && Number.isFinite(numericValue) && value.includes("%") ? <DirectionalPercent value={numericValue} /> : value}
        </div>
      ) : null}
    </Link>
  );
}

function SearchLink({ href, title, subtitle }: { href: string; title: string; subtitle: string }) {
  return <Link to={href} className="kaspa-panel rounded-md p-4 transition hover:border-kaspa-primary/80"><div className="font-bold text-kaspa-text">{title}</div><div className="mt-1 break-all text-xs text-kaspa-muted">{subtitle}</div></Link>;
}

function HomePanel({ title, href, tokens, value }: { title: string; href: string; tokens: HomeSummaryToken[]; value: (token: HomeSummaryToken) => string }) {
  return (
    <div className="kaspa-panel h-full min-h-[480px] rounded-md p-5">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-lg font-bold text-kaspa-text">{title}</h2>
        <Link to={href} className="focus-ring rounded-md border border-kaspa-primary/60 px-3 py-2 text-xs font-bold text-kaspa-primary">Open</Link>
      </div>
      <div className="mt-4 space-y-3">
        {tokens.map((token) => <TokenResult key={token.id} token={token} value={value(token)} showLayer={false} />)}
      </div>
    </div>
  );
}

type KaspaChartMode = "price" | "hashrate";

function KaspaStatsPanel({mode, stats, loading, range, onRange }: {mode:KaspaChartMode; stats: KaspaStats | null; loading: boolean; range: KaspaStatsRange; onRange: (range: KaspaStatsRange) => void }) {
  return (
    <div className="kaspa-panel rounded-md p-5" data-kaspa-chart={mode}>
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-lg font-bold text-kaspa-text">{mode==='price'?'Kaspa Price':'Kaspa Hashrate'}</h2>
        <span className="rounded-sm border border-kaspa-border px-2 py-1 text-[10px] font-bold text-kaspa-muted">Live</span>
      </div>
      {loading ? (
        <div className="mt-4 h-80 animate-pulse rounded-md border border-kaspa-border bg-kaspa-background" />
      ) : (
        <div className="mt-4 space-y-4">
          <div>
            <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
              <div className="flex rounded-md border border-kaspa-border bg-kaspa-background/50 p-1">
                {(["24h", "3d", "7d"] as KaspaStatsRange[]).map((item) => (
                  <button key={item} onClick={() => onRange(item)} className={["focus-ring h-8 rounded-sm px-2 text-[11px] font-bold", range === item ? "bg-kaspa-primary/10 text-kaspa-primary" : "text-kaspa-muted hover:text-kaspa-primary"].join(" ")}>
                    {item}
                  </button>
                ))}
              </div>
            </div>
            <KaspaStatsChart
              mode={mode}
              range={range}
              pricePoints={stats?.price_chart || stats?.chart || []}
              hashratePoints={stats?.hashrate_chart || []}
            />
          </div>
        </div>
      )}
    </div>
  );
}

function KaspaStatsChart({ mode, range, pricePoints, hashratePoints }: { mode: KaspaChartMode; range: KaspaStatsRange; pricePoints: KaspaStatsPoint[]; hashratePoints: KaspaHashratePoint[] }) {
  const [hovered, setHovered] = useState<{ point: { time: number; value: number }; x: number; y: number; ratio: number } | null>(null);
  const points = mode === "price"
    ? pricePoints.map((point) => ({ time: point.time, value: point.price_usd }))
    : hashratePoints.map((point) => ({ time: point.time, value: point.hashrate_kh }));
  const validPoints = points.filter((point): point is {time:number;value:number} => typeof point.value === 'number' && Number.isFinite(point.value) && point.value >= 0 && Number.isFinite(point.time)).sort((a,b) => a.time-b.time);
  const scale = chartScale(validPoints.map(point => point.value));

  useEffect(() => {
    setHovered(null);
  }, [mode, range, pricePoints, hashratePoints]);
  if (!scale) {
    return <div className="flex h-36 items-center justify-center rounded-md border border-kaspa-border bg-kaspa-background/50 text-sm text-kaspa-muted">No chart data</div>;
  }

  const width = 1000;
  const height = 184;
  const chartWidth = width;
  const chartPadding = 24;
  const {low, high} = scale;
  const unit = axisUnit(mode, high);
  const axisLabels = scale.ticks.map(value => axisNumber(value/unit.divisor, scale.step/unit.divisor));
  const axisWidth = Math.max(76, ...axisLabels.map(label => label.length*7+10));
  const valueRange = high - low || 1;
  const first = validPoints[0].time;
  const last = validPoints[validPoints.length - 1].time;
  const timeRange = last - first || 1;
  const path = validPoints
    .map((point, index) => {
      const x = ((point.time - first) / timeRange) * chartWidth;
      const y = height - chartPadding - (((point.value as number) - low) / valueRange) * (height - chartPadding * 2);
      return `${index === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(" ");
  const yFor = (value: number) => height - chartPadding - ((value - low) / valueRange) * (height - chartPadding * 2);
  const firstValue = validPoints[0]?.value ?? null;
  const lastValue = validPoints[validPoints.length - 1]?.value ?? null;
  const changePercent = firstValue !== null && lastValue !== null && firstValue !== 0 ? (lastValue - firstValue) / firstValue * 100 : null;
  const changeTone = changePercent !== null && changePercent >= 0 ? "text-[#00FF00]" : "text-[#FF0000]";
  const title = mode === "price"
    ? `KAS/USDT ${range} price, Gate.io ${range === "24h" ? "15m" : "1h"} candles`
    : `Kaspa ${range} hashrate, api.kaspa.org 1h history`;
  const formatValue = mode === "price" ? formatCurrency : formatHashrate;
  function updateHoveredPoint(event: PointerEvent<SVGSVGElement>) {
    if (validPoints.length === 0) {
      return;
    }
    if (event.pointerType !== "mouse") {
      event.preventDefault();
    }
    const rect = event.currentTarget.getBoundingClientRect();
    const svgX = ((event.clientX - rect.left) / rect.width) * width;
    const clampedX = Math.max(0, Math.min(chartWidth, svgX));
    const hoveredTime = first + (clampedX / chartWidth) * timeRange;
    const nearest = validPoints.reduce((best, point) => Math.abs(point.time - hoveredTime) < Math.abs(best.time - hoveredTime) ? point : best, validPoints[0]);
    const nearestX = ((nearest.time - first) / timeRange) * chartWidth;
    const railWidth = event.currentTarget.parentElement?.clientWidth || rect.width;
    setHovered({ point: nearest, x: nearestX, y: yFor(nearest.value), ratio: nearestX / width * rect.width / railWidth });
  }

  return (
    <div className="rounded-md border border-kaspa-border bg-kaspa-background/50 p-3">
      <div className="relative mb-2 h-11">
        {!hovered ? (
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="text-[11px] font-bold text-kaspa-muted">{title}</div>
            </div>
            <div className={["shrink-0 text-right text-xs font-bold", changePercent === null ? "text-kaspa-muted" : changeTone].join(" ")}>
              {changePercent === null ? "n/a" : formatPercentValue(changePercent)}
            </div>
          </div>
        ) : (
          <div
            className="pointer-events-none absolute top-0 z-10 w-44 rounded-md border border-kaspa-primary/60 bg-kaspa-background/95 px-3 py-1.5 text-xs shadow-[0_0_18px_rgba(0,255,208,0.22)]"
            style={{ left: tooltipRailLeft(hovered.ratio, "11rem") }}
          >
            <div className="font-bold text-kaspa-text">{formatUnixDateTime(hovered.point.time)}</div>
            <div className="mt-0.5 text-kaspa-primary">{formatValue(hovered.point.value)}</div>
          </div>
        )}
      </div>
      <div className="kaspa-chart-plot relative h-[184px]" data-chart-plot>
      <svg
        className="h-full overflow-visible"
        style={{ width: `calc(100% - ${axisWidth}px)`, touchAction: 'none' }}
        preserveAspectRatio="none"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={mode === "price" ? "KAS price chart" : "Kaspa hashrate chart"}
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture?.(event.pointerId);
          updateHoveredPoint(event);
        }}
        onPointerMove={updateHoveredPoint}
        onPointerUp={(event) => {
          event.currentTarget.releasePointerCapture?.(event.pointerId);
          if (event.pointerType === "mouse") setHovered(null);
        }}
        onPointerCancel={() => setHovered(null)}
        onPointerLeave={(event) => {
          if (event.pointerType === "mouse") setHovered(null);
        }}
      >
        <desc>{unit.label} scale: {axisNumber(low / unit.divisor, scale.step / unit.divisor)} to {axisNumber(high / unit.divisor, scale.step / unit.divisor)}</desc>
        {scale.ticks.map((value, index) => (
          <g key={index}>
            <line data-chart-grid x1="0" x2={chartWidth} y1={yFor(value)} y2={yFor(value)} stroke="rgb(var(--kaspa-border))" strokeDasharray="4 5" vectorEffect="non-scaling-stroke" />
          </g>
        ))}
        <path data-chart-line d={path} fill="none" stroke="rgb(var(--kaspa-primary))" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
        {hovered ? (
          <g className="pointer-events-none">
            <line x1={hovered.x} x2={hovered.x} y1={chartPadding} y2={height-chartPadding} stroke="rgb(var(--kaspa-muted))" strokeDasharray="5 5" vectorEffect="non-scaling-stroke" />
            <line x1="0" x2={chartWidth} y1={hovered.y} y2={hovered.y} stroke="rgb(var(--kaspa-muted))" strokeDasharray="5 5" vectorEffect="non-scaling-stroke" />
          </g>
        ) : null}
      </svg>
      {hovered ? <span data-chart-pointer aria-hidden="true" className="pointer-events-none absolute h-2 w-2 rounded-full" style={{left:`calc((100% - ${axisWidth}px) * ${hovered.x/width})`,top:`${hovered.y/height*100}%`,transform:'translate(-50%,-50%)',background:'rgb(var(--kaspa-primary))',boxShadow:'0 0 0 2px rgb(var(--kaspa-background))'}}/> : null}
      <div data-chart-axis className="pointer-events-none absolute inset-y-0 right-0 text-right text-xs text-kaspa-muted" style={{width:axisWidth-8}}>
        <span className="absolute right-0 top-0 text-[10px] font-bold">{unit.label}</span>
        {scale.ticks.map((value,index) => <span data-chart-tick key={value} data-value={value} className="absolute right-0 whitespace-nowrap font-medium tabular-nums" style={{top: `${yFor(value)/height*100}%`, transform:'translateY(-50%)'}}>{axisLabels[index]}</span>)}
      </div>
      </div>
      <div data-chart-time className="mt-1 flex justify-between gap-2 text-[10px] tabular-nums text-kaspa-muted" style={{marginRight:axisWidth}}>
        <span>{chartTime(first, range)}</span><span className="hidden sm:inline">{chartTime(first+(last-first)/2, range)}</span><span>{chartTime(last, range)}</span>
      </div>
    </div>
  );
}

function chartTime(time:number, range:KaspaStatsRange) {
  const date = new Date(time*1000);
  return range === '24h' ? date.toLocaleTimeString('en-US', {hour:'2-digit',minute:'2-digit',hour12:false}) : date.toLocaleDateString('en-US', {month:'short',day:'2-digit'});
}

function tooltipRailLeft(ratio: number, width: string) {
  const preferred = `calc(${ratio * 100}% - 5.5rem)`;
  return `clamp(0px, ${preferred}, calc(100% - ${width}))`;
}

function searchResults(tokens: HomeSummaryToken[], query: string) {
  const normalized = query.trim().toLowerCase();
  if (!normalized || normalized.startsWith("kaspa:") || normalized.startsWith("0x")) {
    return [];
  }
  const matches = tokens
    .filter((token) => token.symbol.toLowerCase().includes(normalized) || token.name.toLowerCase().includes(normalized) || token.layer==='KCC20'&&token.id.toLowerCase()==='kcc20-'+normalized)
    .sort((a, b) => tokenSearchRank(a, normalized) - tokenSearchRank(b, normalized)
      || tokenLayerRank(a.layer) - tokenLayerRank(b.layer)
      || a.symbol.localeCompare(b.symbol));
  return Array.from(new Map(matches.map((token) => [token.id, token])).values()).slice(0, 12);
}

function tokenLayerRank(layer: HomeSummaryToken["layer"]) {
  if (layer === "KRC20") return 0;
  if (layer === "KCC20") return 1;
  if (layer === "KRC721") return 2;
  return 3;
}

function tokenSearchRank(token: HomeSummaryToken, query: string) {
  const symbol = token.symbol.toLowerCase();
  const name = token.name.toLowerCase();
  if (symbol === query) return 0;
  if (symbol.startsWith(query)) return 1;
  if (symbol.includes(query)) return 2;
  if (name === query) return 3;
  if (name.startsWith(query)) return 4;
  return 5;
}

function walletResults(query: string) {
  const trimmed = query.trim();
  if (/^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?\.k$/i.test(trimmed)) {
    return [{ href: `/dotk/${encodeURIComponent(trimmed.toLowerCase())}`, title: "View dot.k covenant name", subtitle: trimmed }];
  }
  if (trimmed.startsWith("kaspa:")) {
    return [{ href: `/wallet/krc20/${encodeURIComponent(trimmed)}`, title: "Open Kaspa wallet", subtitle: trimmed }];
  }
  if (/^[a-z0-9-]+\.kas$/i.test(trimmed)) {
    return [{ href: `/wallet/krc20/${encodeURIComponent(trimmed)}`, title: "Resolve KNS domain", subtitle: trimmed }];
  }
  return [];
}

function labelWalletResults(matches: WalletLabelMatch[]) {
  return matches.flatMap((match) => {
    if (!match.address.startsWith('kaspa:')) return [];
    return [{ href: `/wallet/krc20/${encodeURIComponent(match.address)}`, title: `${match.label} (${match.source} label)`, subtitle: match.address }];
  });
}

function knsDomainResults(domains: KnsDomain[]) {
  return domains.map((domain) => ({
    href: `/wallet/krc20/${encodeURIComponent(domain.name)}`,
    title: domain.name,
    subtitle: domain.owner ? `KNS · ${domain.owner}` : "KNS domain"
  }));
}

function uniqueSearchLinks<T extends { href: string }>(links: T[]) {
  return Array.from(new Map(links.map((link) => [link.href, link])).values()).slice(0, 18);
}

function formatPercentValue(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const arrow = value > 0 ? "▲ " : value < 0 ? "▼ " : "";
  return arrow + new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 2
  }).format(Math.abs(value)) + "%";
}

function formatHashrate(valueKh: number | null | undefined) {
  if (valueKh === null || valueKh === undefined || Number.isNaN(valueKh)) return "n/a";
  const hps = valueKh * 1000;
  const units = [
    { suffix: "EH/s", value: 1e18 },
    { suffix: "PH/s", value: 1e15 },
    { suffix: "TH/s", value: 1e12 }
  ];
  const unit = units.find((item) => hps >= item.value) || units[units.length - 1];
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(hps / unit.value) + " " + unit.suffix;
}

