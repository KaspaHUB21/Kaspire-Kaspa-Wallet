import { Link } from "react-router-dom";
import { useEffect, useMemo, useState } from "react";
import type { ChartPoint, Token } from "../types/token";
import { DirectionalPercent } from "./DirectionalPercent";
import { FavoriteButton } from "./FavoriteButton";
import { formatCurrency, formatKas, formatKasVolume, formatPlainPercent } from "../utils/format";
import { StatusBadge } from "./StatusBadge";
import { TokenLogo } from "./TokenLogo";
import { TokenVolume } from "./TokenVolume";
import { usePortfolioStore } from "../services/portfolio";
import { getChart } from "../services/api";

type TableChartRange = "24h" | "7d" | "30d";

interface TableChartJob {
  tokenId: string;
  range: TableChartRange;
}

interface TableChartResult extends TableChartJob {
  points: ChartPoint[];
}

interface TokenTableProps {
  tokens: Token[];
  rankById: Map<string, number>;
  showMarketData?: boolean;
}

export function TokenTable({ tokens, rankById, showMarketData = true }: TokenTableProps) {
  const { isFavorite } = usePortfolioStore();
  const [chartData, setChartData] = useState<Record<string, {
    changes: Partial<Record<"24h" | "7d", number>>;
    thirtyDay: ChartPoint[];
  }>>({});
  const isKrc721 = tokens.some((token) => token.layer === "KRC721");
  const isOnlyKrc20 = tokens.length > 0 && tokens.every((token) => token.layer === "KRC20");
  const showMint = isOnlyKrc20 && tokens.some((token) =>
    token.mint_percent !== undefined && token.mint_percent !== null ||
    token.premint_percent !== undefined && token.premint_percent !== null
  );
  const showPriceChange = showMarketData && !isKrc721;
  const showSevenDayChange = showPriceChange && isOnlyKrc20;
  const chartChangeKey = useMemo(() => tokens.map((token) => token.id).join("|") + ":" + showPriceChange + ":" + showSevenDayChange, [tokens, showPriceChange, showSevenDayChange]);

  useEffect(() => {
    if (!showPriceChange) {
      return;
    }
    let active = true;
    // The token snapshot already contains 7d changes. Loading another chart
    // for every row doubled upstream traffic and could rate-limit the market
    // feed for all users; only the sparkline needs an on-demand chart.
    const jobs: TableChartJob[] = tokens.map((token) => ({ tokenId: token.id, range: "30d" }));
    loadTableCharts(jobs).then((rows) => {
      if (!active) {
        return;
      }
      setChartData((current) => {
        const next = { ...current };
        for (const row of rows) {
          const entry = next[row.tokenId] || { changes: {}, thirtyDay: [] };
          if (row.range === "30d") {
            next[row.tokenId] = { ...entry, thirtyDay: row.points };
          } else {
            const change = chartDerivedChange(row.points);
            next[row.tokenId] = {
              ...entry,
              changes: change === null ? entry.changes : { ...entry.changes, [row.range]: change }
            };
          }
        }
        return next;
      });
    });
    return () => {
      active = false;
    };
  }, [chartChangeKey, showPriceChange, showSevenDayChange, tokens]);

  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="scrollbar-thin overflow-x-auto">
        <table className="min-w-full divide-y divide-kaspa-border text-sm">
          <thead className="bg-kaspa-background/60 text-xs font-semibold text-kaspa-muted">
              <tr>
              <th className="px-3 py-3 text-left">Rank</th>
              <th className="px-3 py-3 text-left">Token</th>
              {showMarketData ? <th className="px-3 py-3 text-right">Price</th> : null}
              {showPriceChange ? <th className="px-3 py-3 text-right">24h</th> : null}
              {showSevenDayChange ? <th className="px-3 py-3 text-right">7d</th> : null}
              {showMarketData && !isKrc721 ? <th className="px-2 py-3 text-center">Last 30 Days</th> : null}
              {showMarketData && !isKrc721 ? <th className="px-3 py-3 text-right">Market Cap</th> : null}
              {showMarketData ? <th className="px-3 py-3 text-right">24h Vol</th> : null}
              {showMarketData ? <th className="px-3 py-3 text-right">7d Vol</th> : null}
              {showMarketData ? <th className="px-3 py-3 text-right">30d Vol</th> : null}
              {showMarketData && isKrc721 ? <th className="px-3 py-3 text-right">All Time Volume</th> : null}
              {!showMarketData ? <th className="px-3 py-3 text-left">Source</th> : null}
              {showMint ? <th className="px-3 py-3 text-right">Mint / Premint</th> : null}
              {!isKrc721 ? <th className="px-3 py-3 text-right">Status</th> : null}
            </tr>
          </thead>
          <tbody className="divide-y divide-kaspa-border">
            {tokens.map((token) => (
              <tr key={token.id} className={[isFavorite(token.id) ? "bg-kaspa-primary/5" : "", "hover:bg-kaspa-primary/5"].join(" ")}>
                <td className="whitespace-nowrap px-3 py-3">
                  <div className="flex items-center gap-2">
                    <span className="font-bold text-kaspa-muted">#{rankById.get(token.id) || "-"}</span>
                    <FavoriteButton tokenId={token.id} compact bare />
                  </div>
                </td>
                <td className="px-3 py-3">
                  <div className="flex items-center gap-2">
                    <Link to={tokenDetailPath(token)} className="focus-ring flex min-w-0 items-center gap-3 rounded-sm">
                      <TokenLogo src={token.image_url} symbol={token.symbol} size="sm" />
                      <div className="flex min-w-0 items-center gap-1.5">
                        <div className="truncate font-bold text-kaspa-text">{token.symbol}</div>
                        {isDagasWarningToken(token) ? <span className="shrink-0 text-base font-black leading-none text-red-500" title="100% dev minted airdrop token. Metrics have been reported to be not real.">*</span> : null}
                      </div>
                    </Link>
                  </div>
                </td>
                {showMarketData ? <td className="px-3 py-3 text-right"><PriceCell token={token} /></td> : null}
                {showPriceChange ? <td className="px-3 py-3 text-right"><ChangeCell value={changeValue(token, token.price_change_24h_percent, chartData[token.id]?.changes["24h"])} /></td> : null}
                {showSevenDayChange ? <td className="px-3 py-3 text-right"><ChangeCell value={changeValue(token, token.price_change_7d_percent, chartData[token.id]?.changes["7d"])} /></td> : null}
                {showMarketData && !isKrc721 ? <td className="px-2 py-2"><ThirtyDaySparkline points={chartData[token.id]?.thirtyDay || []} /></td> : null}
                {showMarketData && !isKrc721 ? (
                  <td className="px-3 py-3 text-right">
                    {token.unusual_market_cap ? (
                      <div>
                        <div className="font-semibold text-kaspa-text">Unusual market cap detected</div>
                        <div className="text-xs font-semibold text-kaspa-primary">* ({formatCurrency(token.market_cap_usd)})</div>
                      </div>
                    ) : formatCurrency(token.market_cap_usd)}
                  </td>
                ) : null}
                {showMarketData ? <td className="px-3 py-3 text-right">{token.layer === "KRC721" ? formatKasVolume(token.volume_24h_kas) : formatCurrency(token.volume_24h_usd)}</td> : null}
                {showMarketData ? <td className="px-3 py-3 text-right"><TokenVolume token={token} window="7d" /></td> : null}
                {showMarketData ? <td className="px-3 py-3 text-right"><TokenVolume token={token} window="30d" /></td> : null}
                {showMarketData && isKrc721 ? <td className="px-3 py-3 text-right">{formatKasVolume(token.all_time_volume_kas)}</td> : null}
                {!showMarketData ? <td className="max-w-[320px] truncate px-3 py-3 text-left text-kaspa-muted" title={token.source || token.contract_address}>{token.source || token.contract_address || "L2 DEX factory discovery"}</td> : null}
                {showMint ? <td className="px-3 py-3 text-right"><MintPremintCell token={token} /></td> : null}
                {!isKrc721 ? <td className="px-3 py-3 text-right"><StatusBadge verified={token.verified} reason={token.verification_reason} /></td> : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

async function loadTableCharts(jobs: TableChartJob[], concurrency = 4): Promise<TableChartResult[]> {
  const results = new Array<TableChartResult>(jobs.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < jobs.length) {
      const index = nextIndex++;
      const job = jobs[index];
      try {
        const envelope = await getChart(job.tokenId, job.range);
        results[index] = { ...job, points: envelope.data.points };
      } catch {
        results[index] = { ...job, points: [] };
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(concurrency, jobs.length) }, () => worker()));
  return results;
}

function ThirtyDaySparkline({ points }: { points: ChartPoint[] }) {
  const latestTime = points.reduce((latest, point) => Math.max(latest, point.time), 0);
  const windowStart = latestTime - 30 * 24 * 60 * 60;
  const windowPoints = points.filter((point) => point.time >= windowStart && point.time <= latestTime);
  const kasValues = windowPoints
    .filter((point): point is ChartPoint & { price_kas: number } => typeof point.price_kas === "number" && Number.isFinite(point.price_kas) && point.price_kas > 0)
    .map((point) => ({ time: point.time, value: point.price_kas }));
  const usdValues = windowPoints
    .filter((point): point is ChartPoint & { price_usd: number } => typeof point.price_usd === "number" && Number.isFinite(point.price_usd) && point.price_usd > 0)
    .map((point) => ({ time: point.time, value: point.price_usd }));
  const values = kasValues.length >= 2 ? kasValues : usdValues;
  if (values.length < 2) {
    return <div className="mx-auto flex h-8 w-24 items-center justify-center text-xs text-kaspa-muted">-</div>;
  }
  const width = 96;
  const height = 32;
  const minTime = values[0].time;
  const maxTime = values[values.length - 1].time;
  const minValue = Math.min(...values.map((point) => point.value));
  const maxValue = Math.max(...values.map((point) => point.value));
  const timeRange = maxTime - minTime || 1;
  const valueRange = maxValue - minValue || Math.max(Math.abs(maxValue) * 0.01, 1e-12);
  const path = values.map((point, index) => {
    const x = ((point.time - minTime) / timeRange) * width;
    const y = height - 2 - ((point.value - minValue) / valueRange) * (height - 4);
    return `${index === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)}`;
  }).join(" ");
  const change = values[values.length - 1].value - values[0].value;
  const color = change > 0 ? "#00FF00" : change < 0 ? "#FF0000" : "var(--text-muted)";
  return (
    <svg className="mx-auto h-8 w-24" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Last 30 days price chart">
      <path d={path} fill="none" stroke={color} strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
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

function chartDerivedChange(points: Array<{ price_kas: number | null; price_usd: number | null }>) {
  const prices = points
    .map((point) => point.price_kas)
    .filter((price): price is number => typeof price === "number" && Number.isFinite(price) && price > 0);
  if (prices.length < 2) {
    return null;
  }
  return ((prices[prices.length - 1] - prices[0]) / prices[0]) * 100;
}

function changeValue(token: Token, snapshot: number | null | undefined, chart: number | null | undefined) {
  const dexDriven = isDexDrivenKrc20(token);
  if (dexDriven) {
    return typeof chart === "number" && Number.isFinite(chart) ? chart : snapshot;
  }
  if (typeof chart === "number" && Number.isFinite(chart) && Math.abs(chart) > 0.01) {
    return chart;
  }
  return snapshot;
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

function PriceCell({ token }: { token: Token }) {
  const showUsd = token.layer !== "KRC721" && token.price_usd !== null && token.price_usd !== undefined;
  return (
    <div className="leading-tight">
      <div className="font-bold text-kaspa-text">{formatKas(token.price_kas)}</div>
      {showUsd ? <div className="mt-0.5 text-xs font-semibold text-kaspa-muted">{formatCurrency(token.price_usd)}</div> : null}
    </div>
  );
}

function ChangeCell({ value }: { value: number | null | undefined }) {
  const numeric = typeof value === "number" && Number.isFinite(value) ? value : null;
  const style = numeric === null || numeric === 0 ? undefined : { color: numeric > 0 ? "#00FF00" : "#FF0000" };
  return <span className="font-normal text-kaspa-muted" style={style}><DirectionalPercent value={numeric} /></span>;
}

function MintPremintCell({ token }: { token: Token }) {
  const premint = token.premint_percent;
  const hasPremint = typeof premint === "number" && Number.isFinite(premint) && premint > 0;
  return (
    <div className="leading-tight">
      <div className="font-normal text-kaspa-text">{formatPlainPercent(token.mint_percent)}</div>
      <div className="mt-0.5 text-xs font-normal" style={{ color: hasPremint ? "#FF0000" : "#00FF00" }}>
        {formatPlainPercent(premint ?? 0)}
      </div>
    </div>
  );
}

