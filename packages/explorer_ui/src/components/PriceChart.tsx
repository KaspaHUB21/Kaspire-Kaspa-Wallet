import type { ChartPoint } from "../types/token";
import { DirectionalPercent } from "./DirectionalPercent";
import { formatCurrency, formatKas, formatUnixDate, formatUnixDateTime } from "../utils/format";
import { useEffect, useState, type PointerEvent } from "react";

interface PriceChartProps {
  points: ChartPoint[];
  unit: "KAS" | "USD";
  changeOverride?: number | null;
}

export function PriceChart({ points, unit, changeOverride }: PriceChartProps) {
  const [hovered, setHovered] = useState<{ point: ChartPoint; x: number; y: number; ratio: number } | null>(null);
  const dataKey = unit === "KAS" ? "price_kas" : "price_usd";
  const values = points
    .map((point) => point[dataKey])
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value));

  useEffect(() => {
    setHovered(null);
  }, [points, unit]);

  if (points.length === 0 || values.length === 0) {
    return (
      <div className="kaspa-panel flex h-80 items-center justify-center rounded-md p-4 text-sm text-kaspa-muted">
        No chart data available
      </div>
    );
  }

  const width = 920;
  const height = 280;
  const padding = { top: 18, right: 24, bottom: 36, left: 72 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  const rawMin = Math.min(...values);
  const rawMax = Math.max(...values);
  const isFlat = rawMax === rawMin;
  const flatPadding = Math.max(Math.abs(rawMax) * 0.01, 0.00000001);
  const min = isFlat ? rawMin - flatPadding : rawMin;
  const max = isFlat ? rawMax + flatPadding : rawMax;
  const range = max - min || 1;
  const firstTime = points[0]?.time ?? 0;
  const lastTime = points[points.length - 1]?.time ?? firstTime + 1;
  const timeRange = lastTime - firstTime || 1;
  const valueAt = (point: ChartPoint) => point[dataKey];
  const xFor = (time: number) => padding.left + ((time - firstTime) / timeRange) * plotWidth;
  const yFor = (value: number) => padding.top + plotHeight - ((value - min) / range) * plotHeight;
  const validPoints = points.filter((point) => typeof valueAt(point) === "number");
  const path = validPoints
    .map((point, index) => {
      const value = valueAt(point) as number;
      return `${index === 0 ? "M" : "L"} ${xFor(point.time).toFixed(2)} ${yFor(value).toFixed(2)}`;
    })
    .join(" ");
  const areaPath = `${path} L ${xFor(lastTime).toFixed(2)} ${padding.top + plotHeight} L ${xFor(firstTime).toFixed(2)} ${padding.top + plotHeight} Z`;
  const lastValue = values[values.length - 1];
  const firstValue = values[0];
  const derivedChange = firstValue ? ((lastValue - firstValue) / firstValue) * 100 : 0;
  const officialChange = [...points].reverse().find((point) => typeof point.change_percent === "number" && Number.isFinite(point.change_percent))?.change_percent;
  const normalizedOverride = typeof changeOverride === "number" && Number.isFinite(changeOverride) && Math.abs(changeOverride) > 0.000001 ? changeOverride : null;
  const change = normalizedOverride ?? officialChange ?? derivedChange;
  const changeStyle = change > 0 ? { color: "#00FF00" } : change < 0 ? { color: "#FF0000" } : undefined;
  const yTicks = Array.from({ length: 4 }, (_, index) => min + (range / 3) * index).reverse();
  const xTicks = [firstTime, firstTime + timeRange / 2, lastTime];
  const formatValue = (value: number) => unit === "KAS" ? formatKas(value) : formatCurrency(value);

  function updateHoveredPoint(event: PointerEvent<SVGSVGElement>) {
    if (validPoints.length === 0) {
      return;
    }
    if (event.pointerType !== "mouse") {
      event.preventDefault();
    }
    const rect = event.currentTarget.getBoundingClientRect();
    const svgX = ((event.clientX - rect.left) / rect.width) * width;
    const clampedX = Math.max(padding.left, Math.min(width - padding.right, svgX));
    const hoveredTime = firstTime + ((clampedX - padding.left) / plotWidth) * timeRange;
    const nearest = validPoints.reduce((best, point) => Math.abs(point.time - hoveredTime) < Math.abs(best.time - hoveredTime) ? point : best, validPoints[0]);
    const nearestValue = valueAt(nearest);
    if (typeof nearestValue !== "number") {
      return;
    }
    const nearestX = xFor(nearest.time);
    setHovered({ point: nearest, x: nearestX, y: yFor(nearestValue), ratio: nearestX / width });
  }

  function onPointerDown(event: PointerEvent<SVGSVGElement>) {
    event.currentTarget.setPointerCapture?.(event.pointerId);
    updateHoveredPoint(event);
  }

  function onPointerMove(event: PointerEvent<SVGSVGElement>) {
    updateHoveredPoint(event);
  }

  function onPointerUp(event: PointerEvent<SVGSVGElement>) {
    event.currentTarget.releasePointerCapture?.(event.pointerId);
    if (event.pointerType === "mouse") {
      setHovered(null);
    }
  }

  function onPointerLeave(event: PointerEvent<SVGSVGElement>) {
    if (event.pointerType === "mouse") {
      setHovered(null);
    }
  }

  return (
    <div className="kaspa-panel h-80 rounded-md p-4">
      <div className="relative mb-2 h-14">
        {!hovered ? (
          <div className="flex h-full items-start justify-between gap-3">
            <div className="text-lg font-bold text-kaspa-text">{formatValue(lastValue)}</div>
            <div className="text-sm font-normal text-kaspa-muted" style={changeStyle}>
              <DirectionalPercent value={change} />
            </div>
          </div>
        ) : (
          <div
            className="pointer-events-none absolute top-0 z-10 w-52 rounded-md border border-kaspa-primary/60 bg-kaspa-background/95 px-3 py-1.5 text-xs shadow-[0_0_18px_rgba(0,255,208,0.22)]"
            style={{ left: tooltipRailLeft(hovered.ratio, "13rem") }}
          >
            <div className="font-bold text-kaspa-text">{formatUnixDateTime(hovered.point.time)}</div>
            <div className="mt-0.5 flex flex-wrap items-center gap-x-3">
              <span className="text-kaspa-primary">{formatValue(valueAt(hovered.point) as number)}</span>
              {hovered.point.price_kas !== null && unit !== "KAS" ? <span className="text-kaspa-muted">{formatKas(hovered.point.price_kas)}</span> : null}
              {hovered.point.price_usd !== null && unit !== "USD" ? <span className="text-kaspa-muted">{formatCurrency(hovered.point.price_usd)}</span> : null}
            </div>
          </div>
        )}
      </div>
      <svg
        className="h-[210px] w-full overflow-visible"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={`${unit} price chart`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={() => setHovered(null)}
        onPointerLeave={onPointerLeave}
        style={{ touchAction: "none" }}
      >
        <defs>
          <linearGradient id="kaspa-chart-fill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.28" />
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
          </linearGradient>
          <filter id="kaspa-chart-glow" x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        {yTicks.map((tick) => (
          <g key={tick}>
            <line x1={padding.left} x2={width - padding.right} y1={yFor(tick)} y2={yFor(tick)} stroke="var(--border-subtle)" />
            <text x={padding.left - 12} y={yFor(tick) + 4} textAnchor="end" fill="var(--text-muted)" fontSize="12">
              {unit === "KAS" ? formatKas(tick).replace(" KAS", "") : formatCurrency(tick)}
            </text>
          </g>
        ))}
        {xTicks.map((tick) => (
          <text key={tick} x={xFor(tick)} y={height - 8} textAnchor="middle" fill="var(--text-muted)" fontSize="12">
            {formatUnixDate(tick)}
          </text>
        ))}
        <path d={areaPath} fill="url(#kaspa-chart-fill)" />
        <path d={path} fill="none" stroke="var(--accent)" strokeLinecap="round" strokeLinejoin="round" strokeWidth="3" filter="url(#kaspa-chart-glow)" />
        <circle cx={xFor(lastTime)} cy={yFor(lastValue)} r="4.5" fill="var(--accent)" />
        {hovered ? (
          <g className="pointer-events-none">
            <line x1={hovered.x} x2={hovered.x} y1={padding.top} y2={padding.top + plotHeight} stroke="var(--border-strong)" strokeDasharray="5 5" />
            <circle cx={hovered.x} cy={hovered.y} r="6" fill="var(--surface-base)" stroke="var(--accent)" strokeWidth="3" />
          </g>
        ) : null}
      </svg>
    </div>
  );
}

function tooltipRailLeft(ratio: number, width: string) {
  const preferred = `calc(${ratio * 100}% - 6.5rem)`;
  return `clamp(0px, ${preferred}, calc(100% - ${width}))`;
}

