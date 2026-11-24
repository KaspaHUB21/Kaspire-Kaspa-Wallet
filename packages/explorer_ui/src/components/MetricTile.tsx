import type { ReactNode } from "react";

interface MetricTileProps {
  label: string;
  value: ReactNode;
  tone?: "normal" | "primary" | "muted";
  variant?: "default" | "detail";
}

export function MetricTile({ label, value, tone = "normal", variant = "default" }: MetricTileProps) {
  const detail = variant === "detail";
  return (
    <div className="kaspa-panel rounded-md p-4">
      <div className="text-xs font-semibold text-kaspa-muted">{label}</div>
      <div className={["mt-2 text-xl", detail ? "font-normal" : "font-bold", detail ? tone === "muted" ? "text-kaspa-muted" : "text-kaspa-text" : tone === "primary" ? "text-kaspa-primary" : tone === "muted" ? "text-kaspa-muted" : "text-kaspa-text"].join(" ")}>{value}</div>
    </div>
  );
}

