import type { TokenTransaction } from "../types/token";
import { Link } from "react-router-dom";
import { formatDateTime, formatTokenAmount } from "../utils/format";
import { walletUrl } from "../utils/wallet";
import { useWalletLabels, type ResolvedWalletLabel } from "../services/walletLabels";
import { WalletLabelBadge } from "./WalletLabelBadge";
import { useInsDomainLabels } from "../services/insDomains";

interface TxTableProps {
  transactions: TokenTransaction[];
  emptyMessage?: string;
}

function AddressCell({ labelDetailsFor, insLabelFor, tokenId, wallet, mobile = false }: { labelDetailsFor: (address: string | undefined | null) => ResolvedWalletLabel | null; insLabelFor: (address: string | undefined | null) => ResolvedWalletLabel | null; tokenId: string; wallet?: string; mobile?: boolean }) {
  const addressUrl = walletUrl(tokenId, wallet);
  const label = labelDetailsFor(wallet) || insLabelFor(wallet);
  if (!wallet) {
    return <span className="text-kaspa-muted">n/a</span>;
  }
  const addressNode = !addressUrl ? (
    <span className="break-all text-kaspa-muted">{wallet}</span>
  ) : (
    <Link to={addressUrl} className="break-all text-kaspa-primary hover:underline">{wallet}</Link>
  );
  if (mobile) {
    return (
      <div className="min-w-0 space-y-2">
        {label ? <WalletLabelBadge label={label} compact /> : null}
        <div className="min-w-0 font-mono text-[11px] leading-relaxed">{addressNode}</div>
      </div>
    );
  }
  return (
    <div className="flex min-w-0 items-start gap-3">
      <span className="min-w-0 flex-1">{addressNode}</span>
      {label ? <span className="shrink-0"><WalletLabelBadge label={label} compact /></span> : null}
    </div>
  );
}

export function TxTable({ transactions, emptyMessage = "No transactions found" }: TxTableProps) {
  const { labelDetailsFor } = useWalletLabels();
  const insLabelFor = useInsDomainLabels(
    transactions.flatMap((tx) => tx.token_id.startsWith("l2-igra-") ? [tx.from_wallet || tx.wallet, tx.to_wallet] : []),
    transactions.some((tx) => tx.token_id.startsWith("l2-igra-"))
  );

  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2">
        {transactions.length === 0 ? (
          <div className="px-4 py-10 text-center text-kaspa-muted">{emptyMessage}</div>
        ) : null}
        {transactions.map((tx) => (
          <div key={tx.id} className="min-w-0 rounded-md border border-kaspa-border p-4">
            <div className="flex items-start justify-between gap-3">
              <div>
                <span className="rounded-sm border border-kaspa-border px-2 py-1 text-xs capitalize text-kaspa-primary">{tx.type}</span>
                <div className="mt-2 text-sm font-bold text-kaspa-text">{tx.token_symbol || "n/a"}</div>
              </div>
              <div className="text-right">
                <div className="text-[10px] font-bold text-kaspa-muted">Amount</div>
                <div className="mt-1 text-sm font-bold text-kaspa-text">{formatTokenAmount(tx.amount)}</div>
              </div>
            </div>
            <div className="mt-4 grid gap-3">
              <div className="rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                <div className="mb-2 text-[10px] font-bold text-kaspa-muted">From</div>
                <AddressCell labelDetailsFor={labelDetailsFor} insLabelFor={insLabelFor} tokenId={tx.token_id} wallet={tx.from_wallet || tx.wallet} mobile />
              </div>
              <div className="rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                <div className="mb-2 text-[10px] font-bold text-kaspa-muted">To</div>
                <AddressCell labelDetailsFor={labelDetailsFor} insLabelFor={insLabelFor} tokenId={tx.token_id} wallet={tx.to_wallet} mobile />
              </div>
            </div>
            <div className="mt-3 text-right text-xs text-kaspa-muted">{formatDateTime(tx.timestamp)}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

