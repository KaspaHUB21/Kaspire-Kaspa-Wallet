import { Link } from 'react-router-dom';
import { MetricTile } from './MetricTile';
import { BarChart3 } from './icons';
import { KnsVolumeChart } from '../pages/KnsPage';
import { useDotk, type DotkMarket } from '../services/dotk';
import { formatDateTime, formatInteger, formatKas } from '../utils/format';

const date = (value: number) => formatDateTime(new Date(value).toISOString());

export function DotkMarketOverview({ query, registeredTotal }: { query: string; registeredTotal?: number }) {
  const state = useDotk<DotkMarket>('marketplace?' + new URLSearchParams({ query }));
  const data = state.data;
  const latest = data?.graph[data.graph.length - 1];
  return <div className="grid gap-6">
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
      <MetricTile label="Registered Names" value={registeredTotal == null ? '—' : formatInteger(registeredTotal)} tone="primary" />
      <MetricTile label="Marketplace Volume" value={data ? formatKas(data.totals.volume_kas) : '—'} />
      <MetricTile label="Marketplace Trades" value={data ? formatInteger(data.totals.trades) : '—'} />
      <MetricTile label="Latest Daily Volume" value={data ? formatKas(latest?.total_volume_kas) : '—'} />
    </div>
    {state.loading ? <p role="status" className="text-kaspa-muted">Loading Kaspire Marketplace data…</p> : null}
    {state.error ? <div role="alert" className="kaspa-panel rounded-md p-4 text-sm text-kaspa-muted">{state.error} Registered names remain available independently.</div> : null}
    {data ? <>
      <div className="kaspa-panel rounded-md p-4 text-sm text-kaspa-muted">
        <p>{data.coverage.note}</p>
        <p className="mt-1">Archive started {date(data.coverage.since)} · Snapshot {date(data.indexedAt)}. Totals cover all recorded names; search filters Top Names and Recent Sales.</p>
      </div>
      <div className="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(340px,0.8fr)]">
        <KnsVolumeChart points={data.graph} market="dot.k · Kaspire Marketplace" />
        <div className="kaspa-panel rounded-md p-4">
          <div className="mb-3 flex items-center gap-2"><BarChart3 className="h-4 w-4 text-kaspa-primary" /><h2 className="text-lg font-bold text-kaspa-text">Top Names</h2></div>
          <div className="grid gap-2">{data.top_domains.map(row => <Link key={row.domain} to={'/dotk/' + encodeURIComponent(row.domain)} className="flex items-center justify-between gap-3 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
            <div className="min-w-0"><div className="break-all font-bold text-kaspa-text">{row.domain}</div><div className="text-xs text-kaspa-muted">{formatInteger(row.total_trades)} trades</div></div>
            <div className="shrink-0 text-right text-sm font-semibold text-kaspa-primary">{formatKas(row.total_volume_kas)}</div>
          </Link>)}{!data.top_domains.length ? <p className="text-sm text-kaspa-muted">No confirmed trade statistics found.</p> : null}</div>
        </div>
      </div>
      <div className="kaspa-panel overflow-hidden rounded-md">
        <div className="border-b border-kaspa-border px-4 py-3"><h2 className="text-lg font-bold text-kaspa-text">Recent Sales</h2></div>
        <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2">
          {data.recent_sales.slice(0, 15).map(sale => <article key={sale.transaction_id} className="min-w-0 rounded-md border border-kaspa-border p-4">
            <h3 className="break-all font-bold"><Link to={'/dotk/' + encodeURIComponent(sale.domain)}>{sale.domain}</Link></h3>
            <dl className="explorer-facts mt-3 space-y-3">
              <div><dt>Price</dt><dd>{formatKas(sale.price_kas)}</dd></div>
              <div><dt>Buyer deed</dt><dd>{sale.buyer_deed_address || 'n/a'}</dd></div>
              <div><dt>Seller</dt><dd><Link to={'/wallet/krc20/' + encodeURIComponent(sale.seller)}>{sale.seller}</Link></dd></div>
              <div><dt>Fulfilled</dt><dd>{date(sale.timestamp)}</dd></div>
              <div><dt>Transaction</dt><dd><Link to={'/tx/' + encodeURIComponent(sale.transaction_id)}>{sale.transaction_id}</Link></dd></div>
            </dl>
          </article>)}
        </div>
        {!data.recent_sales.length ? <p className="p-4 text-sm text-kaspa-muted">No confirmed sales found.</p> : null}
        <p className="border-t border-kaspa-border p-4 text-xs text-kaspa-muted">Buyer deed is the purchased name’s covenant address, not a payment address. Only confirmed purchases count; listings and cancellations do not.</p>
      </div>
    </> : null}
  </div>;
}

