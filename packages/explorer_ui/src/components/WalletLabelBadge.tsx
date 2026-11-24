import type { ResolvedWalletLabel } from "../services/walletLabels";

export function WalletLabelBadge({ label, compact = false }: { label: ResolvedWalletLabel; compact?: boolean }) {
  const colorClass = label.source === "global"
    ? "border-amber-300/70 bg-amber-300/10 text-amber-200 shadow-[0_0_12px_rgba(252,211,77,0.16)]"
    : label.source === "ins"
      ? "border-cyan-300/60 bg-cyan-300/10 text-cyan-200 shadow-[0_0_12px_rgba(103,232,249,0.16)]"
      : "border-kaspa-primary/50 bg-kaspa-primary/10 text-kaspa-primary";
  const sizeClass = compact ? "px-2 py-0.5 text-[11px]" : "px-2 py-1 text-xs";
  return <span className={`inline-flex max-w-full rounded-md border font-sans font-bold ${sizeClass} ${colorClass}`}>{label.label}</span>;
}

