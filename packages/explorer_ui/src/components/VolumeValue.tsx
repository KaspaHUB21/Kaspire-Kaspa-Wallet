import { formatCurrency, formatKas } from "../utils/format";

export function VolumeValue({ usd, kas, kasUsd }: { usd?: number | null; kas?: number | null; kasUsd?: number | null }) {
  const rate = kasUsd != null && Number.isFinite(kasUsd) && kasUsd > 0 ? kasUsd : null;
  const usdValue = usd ?? (kas === 0 ? 0 : kas != null && rate !== null ? kas * rate : null);
  const kasValue = kas ?? (usd === 0 ? 0 : usd != null && rate !== null ? usd / rate : null);
  return (
    <span className="leading-tight" data-volume-value>
      <span className="block" data-volume-currency="USD">{formatCurrency(usdValue)}</span>
      <span className="mt-1 block text-xs font-semibold text-kaspa-muted" data-volume-currency="KAS">{formatKas(kasValue)}</span>
    </span>
  );
}

