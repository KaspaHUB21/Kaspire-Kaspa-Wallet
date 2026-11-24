import { Link } from "react-router-dom";
import type { Token } from "../types/token";
import { DirectionalPercent } from "./DirectionalPercent";
import { formatKas } from "../utils/format";
import { TokenLogo } from "./TokenLogo";

interface MoverPanelProps {
  title: string;
  tokens: Token[];
  changeField: "price_change_7d_percent" | "price_change_24h_percent";
}

export function MoverPanel({ title, tokens, changeField }: MoverPanelProps) {
  return (
    <div className="kaspa-panel rounded-md p-4">
      <div className="text-xs font-semibold text-kaspa-muted">{title}</div>
      {tokens.length === 0 ? (
        <div className="mt-5 rounded-sm border border-kaspa-border bg-kaspa-background/60 px-3 py-4 text-sm text-kaspa-muted">No price-change data available</div>
      ) : (
        <div className="mt-4 space-y-3">
          {tokens.map((token, index) => {
            const change = token[changeField];
            const changeStyle = typeof change === "number" && Number.isFinite(change)
              ? { color: change > 0 ? "#00FF00" : change < 0 ? "#FF0000" : undefined }
              : undefined;
            return (
              <Link key={token.id} to={token.layer === "KCC20" && token.contract_address ? "/kcc20/" + encodeURIComponent(token.contract_address) : "/token/" + encodeURIComponent(token.id)} className="focus-ring grid grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-3 rounded-sm py-1 transition hover:bg-kaspa-primary/5">
                <span className="text-sm font-bold text-kaspa-muted">{index + 1}</span>
                <span className="flex min-w-0 items-center gap-3">
                  <TokenLogo src={token.image_url} symbol={token.symbol} size="sm" />
                  <span className="min-w-0">
                    <span className="block truncate text-sm font-bold text-kaspa-text">{token.symbol}</span>
                  </span>
                  <span className="rounded-sm border border-kaspa-primary/50 bg-kaspa-primary/10 px-2 py-0.5 text-[10px] font-bold text-kaspa-primary">{token.layer}</span>
                </span>
                <span className="text-right">
                  <span className="block text-xs text-kaspa-muted">{formatKas(token.price_kas)}</span>
                  <span className="block text-sm font-normal text-kaspa-muted" style={changeStyle}><DirectionalPercent value={change} /></span>
                </span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

