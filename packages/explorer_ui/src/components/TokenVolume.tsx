import type { Token } from "../types/token";
import { formatCurrencyWindow, formatKasVolume } from "../utils/format";
import { hasVolumeWindow } from "../utils/token";

export function TokenVolume({ token, window }: { token: Token; window: "7d" | "30d" }) {
  if (token.layer === "KRC721") return <>{formatKasVolume(window === "7d" ? token.volume_7d_kas : token.volume_30d_kas)}</>;
  const value = window === "7d" ? token.volume_7d_usd : token.volume_30d_usd;
  const history = token.layer === "KCC20" ? window === "7d" ? token.volume_7d_history : token.volume_30d_history : undefined;
  const available = hasVolumeWindow(token, window);
  if (!history) return <>{formatCurrencyWindow(value, available)}</>;
  const partial = history.status === "partial";
  const hours = history.covered_hours-history.missing_fx_hours;
  const since = history.from === null ? "No recorded history." : `History from ${new Date(history.from*1000).toISOString().slice(0,16).replace("T"," ")} UTC.`;
  const title = `${partial ? "Incomplete recorded" : history.status === "complete" ? "Complete" : "Unavailable"} ${window} USD volume, using closed hours only. ${hours}/${history.expected_hours} hours covered in USD; ${history.missing_hours} hours unconfirmed; ${history.missing_fx_hours} trading hours lack historical KAS/USD rates. ${since} This describes volume coverage, not the age of the price history. Days without trades retain the last known token price; confirmed zero-trade periods add no volume. Missing volume is not estimated.`;
  return (
    <span className="inline-block" title={title} data-volume-window={window} data-volume-status={history.status}>
      <span className="block">{formatCurrencyWindow(value, available)}{partial ? <sup className="ml-0.5 text-[10px] font-normal text-kaspa-muted" aria-label="Incomplete USD volume history">*</sup> : null}</span>
      {!available && history.covered_hours > 0 ? <span className="block text-[10px] font-normal text-kaspa-muted">USD history unavailable</span> : null}
    </span>
  );
}

