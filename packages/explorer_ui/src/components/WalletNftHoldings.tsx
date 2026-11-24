import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Users } from "./icons";
import type { WalletTokenBalance } from "../types/token";
import { formatTokenAmount } from "../utils/format";
import {publicImage} from '../images';

interface WalletNftHoldingsProps {
  address: string;
  tokens: WalletTokenBalance[];
  loading: boolean;
  error: string | null;
  confirmed: boolean;
}

export function WalletNftHoldings({ address, tokens, loading, error, confirmed }: WalletNftHoldingsProps) {
  const [expanded, setExpanded] = useState(false);
  useEffect(() => setExpanded(false), [address]);
  const visible = expanded ? tokens : tokens.slice(0, 8);
  return (
    <div className="kaspa-panel mb-5 rounded-md p-5" data-wallet-nfts>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="inline-flex items-center gap-2 text-lg font-bold text-kaspa-text"><Users className="h-5 w-5 text-kaspa-primary" /> KRC721 Holdings</h2>
        {tokens.length > 8 ? <button onClick={() => setExpanded(value => !value)} className="focus-ring rounded-md border border-kaspa-border px-3 py-2 text-sm font-bold text-kaspa-text">{expanded ? "Show less" : "Show all"}</button> : null}
      </div>
      {loading && !visible.length ? <div role="status" className="mt-4 text-sm text-kaspa-muted">Loading KRC721 holdings…</div> : null}
      {error ? <div role="status" className="mt-4 text-sm text-kaspa-muted">{visible.length ? "KRC721 refresh temporarily unavailable. Showing the last loaded holdings." : "KRC721 holdings temporarily unavailable. Retrying automatically; this does not mean the wallet is empty."}</div> : null}
      {!loading && !error && confirmed && visible.length === 0 ? <div className="mt-4 text-sm text-kaspa-muted">No KRC721 holdings found</div> : null}
      {visible.length > 0 ? (
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {visible.map(token => (
            <Link to={`/wallet/krc20/${encodeURIComponent(address)}/krc721/${encodeURIComponent(token.symbol)}`} key={token.token_id || token.symbol} className="rounded-md border border-kaspa-border bg-kaspa-background p-4 transition hover:border-kaspa-primary/70">
              <div className="flex items-center gap-3">
                {token.image_url ? <img src={publicImage(token.image_url)} alt="" loading="lazy" decoding="async" width="64" height="64" className="h-16 w-16 rounded-md border border-kaspa-border object-cover" /> : null}
                <div className="min-w-0"><div className="truncate text-sm font-bold text-kaspa-text">{token.symbol}</div>{token.name ? <div className="mt-1 truncate text-xs text-kaspa-muted">{token.name}</div> : null}</div>
              </div>
              <div className="mt-3 text-lg font-bold text-kaspa-primary">{formatTokenAmount(token.balance)}</div>
            </Link>
          ))}
        </div>
      ) : null}
    </div>
  );
}

