import { FormEvent, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { NamesNav } from "../components/NamesNav";
import { EmptyState } from "../components/EmptyState";
import { LoadingState } from "../components/LoadingState";
import { MetricTile } from "../components/MetricTile";
import { BarChart3, Search } from "../components/icons";
import { useKnsMarketplace } from "../services/tokens";
import type { KnsGraphPoint } from "../types/token";
import { formatDateTime, formatInteger, formatKas, formatUnixDate } from "../utils/format";

export function KnsPage() {
  const [draftQuery, setDraftQuery] = useState("");
  const [query, setQuery] = useState("");
  const state = useKnsMarketplace(query);
  const data = state.data;
  const latestPoint = data?.graph[data.graph.length - 1] || null;
  const visibleSales = data?.recent_sales.slice(0, 15) || [];
  const visibleTopDomains = data?.top_domains.slice(0, 8) || [];
  const submittedDomain = /^[a-z0-9-]+\.kas$/i.test(query.trim()) ? query.trim().toLowerCase() : "";
  const matchingDomain = submittedDomain && data?.domains.some((domain) => domain.name.toLowerCase() === submittedDomain) ? submittedDomain : "";
  const missingDomain = Boolean(submittedDomain && data && !matchingDomain);

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setQuery(draftQuery.trim());
  }

  return (
    <section>
      <NamesNav />
      <div className="mb-6 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="text-sm font-bold text-kaspa-primary">KNS</div>
          <h1 className="mt-1 text-3xl font-bold text-kaspa-text">KNS Explorer</h1>
        </div>
        <form onSubmit={submitSearch} className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <label className="focus-within:shadow-kaspa flex h-10 min-w-[280px] items-center gap-2 rounded-md border border-kaspa-border bg-kaspa-card px-3 transition focus-within:border-kaspa-primary">
            <Search className="h-4 w-4 text-kaspa-muted" aria-hidden="true" />
            <input value={draftQuery} onChange={(event) => setDraftQuery(event.target.value)} placeholder="Search .kas domain" className="w-full bg-transparent text-sm text-kaspa-text outline-none placeholder:text-kaspa-muted" />
          </label>
          <button className="focus-ring h-10 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary shadow-kaspa" type="submit">Search</button>
        </form>
      </div>

      {matchingDomain ? (
        <Link
          to={`/wallet/krc20/${encodeURIComponent(matchingDomain)}`}
          className="focus-ring mb-6 flex min-h-14 items-center justify-between gap-4 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-5 py-4 text-kaspa-primary shadow-kaspa transition hover:bg-kaspa-primary/15"
        >
          <div>
            <div className="text-lg font-black">Check wallet</div>
            <div className="mt-1 break-all text-sm text-kaspa-muted">Resolve {matchingDomain} and open the connected Kaspa wallet.</div>
          </div>
          <Search className="h-5 w-5 shrink-0" aria-hidden="true" />
        </Link>
      ) : null}

      {missingDomain ? (
        <div className="kaspa-panel mb-6 rounded-md p-4 text-sm text-kaspa-muted">
          No registered KNS domain found for {submittedDomain}.
        </div>
      ) : null}

      {state.loading ? <LoadingState /> : null}
      {state.error ? <EmptyState title="KNS unavailable" body={state.error} /> : null}

      {!state.loading && !state.error && data ? (
        <div className="grid gap-6">
          {state.envelope?.warnings?.length ? (
            <div className="kaspa-panel rounded-md p-4 text-sm text-kaspa-muted">
              {state.envelope.warnings.join(" ")}
            </div>
          ) : null}

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <MetricTile label="Registered Domains" value={formatInteger(data.domains_total)} tone="primary" />
            <MetricTile label="Marketplace Volume" value={formatKas(data.totals.volume_kas)} />
            <MetricTile label="Marketplace Trades" value={formatInteger(data.totals.trades)} />
            <MetricTile label="Latest Daily Volume" value={formatKas(latestPoint?.total_volume_kas)} />
          </div>

          <div className="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(340px,0.8fr)]">
            <KnsVolumeChart points={data.graph} />
            <div className="kaspa-panel rounded-md p-4">
              <div className="mb-3 flex items-center gap-2">
                <BarChart3 className="h-4 w-4 text-kaspa-primary" aria-hidden="true" />
                <h2 className="text-lg font-bold text-kaspa-text">Top Domains</h2>
              </div>
              <div className="grid gap-2">
                {visibleTopDomains.map((domain) => (
                  <div key={domain.domain} className="flex items-center justify-between gap-3 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                    <div className="min-w-0">
                      <div className="truncate font-bold text-kaspa-text" title={domain.domain}>{domain.domain}</div>
                      <div className="text-xs text-kaspa-muted">{formatInteger(domain.total_trades)} trades</div>
                    </div>
                    <div className="shrink-0 text-right text-sm font-semibold text-kaspa-primary">{formatKas(domain.total_volume_kas)}</div>
                  </div>
                ))}
                {visibleTopDomains.length === 0 ? <div className="text-sm text-kaspa-muted">No trade stats found.</div> : null}
              </div>
            </div>
          </div>

          <div className="kaspa-panel overflow-hidden rounded-md">
            <div className="border-b border-kaspa-border px-4 py-3">
              <h2 className="text-lg font-bold text-kaspa-text">Recent Sales</h2>
            </div>
            <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2">
              {visibleSales.map((sale, index) => (
                <article key={`${sale.domain}-${sale.timestamp}-${index}`} className="min-w-0 rounded-md border border-kaspa-border p-4">
                  <h3 className="break-all font-bold">{sale.domain}</h3>
                  <dl className="explorer-facts mt-3 space-y-3">
                    <div><dt>Price</dt><dd>{formatKas(sale.price_kas)}</dd></div>
                    <div><dt>Buyer</dt><dd>{sale.buyer ? <Link to={"/wallet/krc20/" + encodeURIComponent(sale.buyer)}>{sale.buyer}</Link> : "n/a"}</dd></div>
                    <div><dt>Seller</dt><dd>{sale.seller ? <Link to={"/wallet/krc20/" + encodeURIComponent(sale.seller)}>{sale.seller}</Link> : "n/a"}</dd></div>
                    <div><dt>Fulfilled</dt><dd>{formatDateTime(sale.timestamp)}</dd></div>
                  </dl>
                </article>
              ))}
            </div>
            {visibleSales.length === 0 ? <div className="p-4 text-sm text-kaspa-muted">No sales found.</div> : null}
          </div>
        </div>
      ) : null}
    </section>
  );
}

export function KnsVolumeChart({ points, market = "KNS" }: { points: Pick<KnsGraphPoint, "time" | "total_volume_kas" | "total_trades">[]; market?: string }) {
  const chartPoints = useMemo(() => points.slice(-30), [points]);
  const values = chartPoints.map((point) => point.total_volume_kas).filter((value) => Number.isFinite(value));
  if (chartPoints.length === 0 || values.length === 0) {
    return <div className="kaspa-panel flex h-80 items-center justify-center rounded-md p-4 text-sm text-kaspa-muted">No analytics data available</div>;
  }

  const width = 920;
  const height = 280;
  const padding = { top: 18, right: 24, bottom: 36, left: 72 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  const rawMax = Math.max(...values);
  const max = rawMax > 0 ? rawMax : 1;
  const firstTime = chartPoints[0]?.time ?? 0;
  const lastTime = chartPoints[chartPoints.length - 1]?.time ?? firstTime + 1;
  const timeRange = lastTime - firstTime || 1;
  const xFor = (time: number) => chartPoints.length === 1 ? padding.left + plotWidth / 2 : padding.left + ((time - firstTime) / timeRange) * plotWidth;
  const yFor = (value: number) => padding.top + plotHeight - (value / max) * plotHeight;
  const path = chartPoints.map((point, index) => `${index === 0 ? "M" : "L"} ${xFor(point.time).toFixed(2)} ${yFor(point.total_volume_kas).toFixed(2)}`).join(" ");
  const areaPath = `${path} L ${xFor(lastTime).toFixed(2)} ${padding.top + plotHeight} L ${xFor(firstTime).toFixed(2)} ${padding.top + plotHeight} Z`;
  const latest = chartPoints[chartPoints.length - 1];
  const yTicks = [max, max * 0.66, max * 0.33, 0];
  const xTicks = chartPoints.length === 1 ? [firstTime] : [firstTime, firstTime + timeRange / 2, lastTime];

  return (
    <div className="kaspa-panel h-80 rounded-md p-4">
      <div className="mb-2 flex items-center justify-between gap-3">
        <div>
          <div className="text-lg font-bold text-kaspa-text">{formatKas(latest.total_volume_kas)}</div>
          <div className="text-xs text-kaspa-muted">Daily {market} sales volume, last 30 points · UTC</div>
        </div>
        <div className="text-sm text-kaspa-muted">{formatInteger(latest.total_trades)} trades</div>
      </div>
      <svg className="h-[244px] w-full overflow-visible" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${market} daily sales volume chart`}>
        <defs>
          <linearGradient id="kns-chart-fill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.28" />
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
          </linearGradient>
        </defs>
        {yTicks.map((tick) => (
          <g key={tick}>
            <line x1={padding.left} x2={width - padding.right} y1={yFor(tick)} y2={yFor(tick)} stroke="var(--border-subtle)" />
            <text x={padding.left - 12} y={yFor(tick) + 4} textAnchor="end" fill="var(--text-muted)" fontSize="12">
              {formatKas(tick).replace(" KAS", "")}
            </text>
          </g>
        ))}
        {xTicks.map((tick) => (
          <text key={tick} x={xFor(tick)} y={height - 8} textAnchor="middle" fill="var(--text-muted)" fontSize="12">
            {formatUnixDate(tick)}
          </text>
        ))}
        <path d={areaPath} fill="url(#kns-chart-fill)" />
        <path d={path} fill="none" stroke="var(--accent)" strokeLinecap="round" strokeLinejoin="round" strokeWidth="3" />
        {chartPoints.length === 1 ? <circle cx={xFor(firstTime)} cy={yFor(latest.total_volume_kas)} r="5" fill="var(--accent)" /> : null}
      </svg>
    </div>
  );
}

