import { useEffect, useMemo, useState } from "react";
import type { Holder, HolderActivity } from "../types/token";
import { Link } from "react-router-dom";
import { formatCompact, formatDateTimeSeconds, formatDaysSince, formatPercent } from "../utils/format";
import { walletUrl } from "../utils/wallet";
import { useWalletLabels, type ResolvedWalletLabel } from "../services/walletLabels";
import { WalletLabelBadge } from "./WalletLabelBadge";
import { useInsDomainLabels } from "../services/insDomains";
import { getHolderActivity } from "../services/api";

interface HolderTableProps {
  holders: Holder[];
  tokenId: string;
}

export function HolderTable({ holders, tokenId }: HolderTableProps) {
  const { labelDetailsFor } = useWalletLabels();
  const insLabelFor = useInsDomainLabels(holders.map((holder) => holder.address), tokenId.startsWith("l2-igra-"));
  const showLastTokenTx = tokenId.startsWith("krc20-");
  const addressesKey = holders.map((holder) => holder.address.toLowerCase()).join("|");
  const [activity, setActivity] = useState<Map<string, HolderActivity>>(() => new Map());
  const [activityLoading, setActivityLoading] = useState(false);

  useEffect(() => {
    let active = true;
    if (!showLastTokenTx || !addressesKey) {
      setActivity(new Map());
      setActivityLoading(false);
      return () => { active = false; };
    }
    setActivity(new Map());
    setActivityLoading(true);
    void (async () => {
      const addresses = addressesKey.split("|");
      const requestSize = 25;
      try {
        for (let offset = 0; offset < addresses.length; offset += requestSize) {
          const envelope = await getHolderActivity(tokenId, addresses.slice(offset, offset + requestSize));
          if (!active) return;
          setActivity((current) => {
            const next = new Map(current);
            for (const item of envelope.data.activity) {
              next.set(item.address.toLowerCase(), item);
            }
            return next;
          });
        }
      } catch {
        // Keep already loaded batches visible when a later activity request fails.
      } finally {
        if (active) setActivityLoading(false);
      }
    })();
    return () => { active = false; };
  }, [addressesKey, showLastTokenTx, tokenId]);

  const holdersWithActivity = useMemo(() => holders.map((holder) => ({
    ...holder,
    ...(activity.get(holder.address.toLowerCase()) || {})
  })), [activity, holders]);

  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="explorer-card-grid grid gap-3 p-3 sm:grid-cols-2">
        {holdersWithActivity.map((holder, index) => (
          <div key={holder.address} className="min-w-0 rounded-md border border-kaspa-border p-4">
            <div className="flex items-center justify-between gap-3">
              <div className="text-sm font-bold text-kaspa-muted">#{index + 1}</div>
              {labelDetailsFor(holder.address) || insLabelFor(holder.address) ? (
                <WalletLabelBadge label={(labelDetailsFor(holder.address) || insLabelFor(holder.address))!} compact />
              ) : null}
            </div>
            <div className="mt-3 font-mono text-[11px] leading-relaxed">
              <HolderAddress tokenId={tokenId} address={holder.address} label={null} mobile />
            </div>
            <div className="mt-3 grid grid-cols-2 gap-3">
              <div className="rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                <div className="text-[10px] font-bold text-kaspa-muted">Supply</div>
                <div className="mt-1 text-sm font-bold text-kaspa-primary">{formatPercent(holder.percentage)}</div>
              </div>
              <div className="rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2 text-right">
                <div className="text-[10px] font-bold text-kaspa-muted">Balance</div>
                <div className="mt-1 text-sm font-bold text-kaspa-text">{formatCompact(holder.balance)}</div>
              </div>
              {showLastTokenTx ? (
                <div className="col-span-2 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                  <div className="text-[10px] font-bold text-kaspa-muted">Last TX for this token</div>
                  <LastTransactionAge value={holder.last_tx_at} loading={activityLoading} emptyTitle="No indexed transaction found for this token" />
                </div>
              ) : null}
              {showLastTokenTx ? (
                <div className="col-span-2 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                  <div className="text-[10px] font-bold text-kaspa-muted">Last TX</div>
                  <LastTransactionAge value={holder.last_wallet_tx_at} loading={activityLoading} emptyTitle="No accepted Kaspa transaction found for this wallet" />
                </div>
              ) : null}
            </div>
          </div>
        ))}
      </div>
      <HolderConcentration holders={holders} />
    </div>
  );
}

function LastTransactionAge({ value, loading, emptyTitle }: { value: string | null | undefined; loading: boolean; emptyTitle: string }) {
  return (
    <span className="mt-1 block whitespace-nowrap font-bold text-kaspa-text" title={value ? formatDateTimeSeconds(value) : emptyTitle}>
      {loading && value === undefined ? "Loading…" : formatDaysSince(value)}
    </span>
  );
}

function HolderConcentration({ holders }: { holders: Holder[] }) {
  const buckets = [10, 25, 50, 100].map((count) => ({
    count,
    value: holders.slice(0, count).reduce((sum, holder) => sum + holder.percentage, 0)
  }));
  const available = holders.length;
  if (available === 0) {
    return null;
  }

  return (
    <div className="border-t border-kaspa-border bg-kaspa-background/35 p-5">
      <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h3 className="text-base font-bold text-kaspa-text">Holder Concentration</h3>
          <div className="mt-1 text-xs text-kaspa-muted">Share of supply held by the largest visible wallets</div>
        </div>
        <div className="text-xs font-bold text-kaspa-muted">Top {Math.min(available, 100)} holders loaded</div>
      </div>
      <div className="grid gap-3 lg:grid-cols-4">
        {buckets.map((bucket) => {
          const cappedValue = Math.max(0, Math.min(100, bucket.value));
          const disabled = available < bucket.count;
          return (
            <div key={bucket.count} className="rounded-md border border-kaspa-border bg-kaspa-card/70 p-4">
              <div className="flex items-center justify-between gap-3">
                <div className="text-sm font-bold text-kaspa-text">Top {bucket.count}</div>
                <div className={["text-sm font-black", disabled ? "text-kaspa-muted" : "text-kaspa-primary"].join(" ")}>{formatPercent(bucket.value)}</div>
              </div>
              <div className="mt-3 h-3 overflow-hidden rounded-full border border-kaspa-border bg-kaspa-background">
                <div
                  className="h-full rounded-full bg-gradient-to-r from-kaspa-primary via-[#5fffe4] to-kaspa-primary shadow-[0_0_16px_rgba(0,255,208,0.45)]"
                  style={{ width: `${cappedValue}%` }}
                />
              </div>
              <div className="mt-2 text-[11px] text-kaspa-muted">
                {disabled ? `Only ${available} holders available` : `${bucket.count} wallets`}
              </div>
            </div>
          );
        })}
      </div>
      <div className="mt-4 flex justify-center rounded-md border border-kaspa-primary/50 bg-kaspa-primary/5 p-3">
        <a href="https://devtools.kaslab.space/" target="_blank" rel="noreferrer" className="focus-ring inline-flex min-h-10 w-full items-center justify-center rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-black text-kaspa-primary shadow-[0_0_12px_rgba(0,255,208,0.18)] transition hover:bg-kaspa-primary hover:text-kaspa-background sm:w-auto">
          Get KRC20 snapshot of all holders
        </a>
      </div>
    </div>
  );
}

function HolderAddress({ tokenId, address, label, mobile = false }: { tokenId: string; address: string; label: ResolvedWalletLabel | null; mobile?: boolean }) {
  const url = walletUrl(tokenId, address);
  const addressNode = !url
    ? <span className={mobile ? "break-all text-kaspa-muted" : "whitespace-nowrap text-kaspa-muted"}>{address}</span>
    : <Link to={url} className={mobile ? "break-all text-kaspa-primary hover:underline" : "whitespace-nowrap text-kaspa-primary hover:underline"}>{address}</Link>;
  if (mobile) {
    return <div className="min-w-0">{addressNode}</div>;
  }
  return (
    <div className="inline-flex min-w-full items-center gap-4">
      <span className="shrink-0">{addressNode}</span>
      {label ? <span className="ml-auto shrink-0"><WalletLabelBadge label={label} compact /></span> : null}
    </div>
  );
}

