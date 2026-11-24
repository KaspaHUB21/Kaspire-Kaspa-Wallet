import { ChangeEvent, FormEvent, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { DirectionalPercent } from "../components/DirectionalPercent";
import { AlertTriangle, Download, Pencil, PieChart, Trash2, Upload, X } from "../components/icons";
import { EmptyState } from "../components/EmptyState";
import { LoadingState } from "../components/LoadingState";
import { MetricTile } from "../components/MetricTile";
import { TokenLogo } from "../components/TokenLogo";
import { WalletLabelBadge } from "../components/WalletLabelBadge";
import { getChart, getWallet } from "../services/api";
import { numericBalance, PortfolioTransaction, usePortfolioStore } from "../services/portfolio";
import { useExplorerTokens } from "../services/tokens";
import { useWalletLabels, type ResolvedWalletLabel, type WalletLabelMatch } from "../services/walletLabels";
import type { ChartPoint, Token, WalletNetwork, WalletTokenBalance } from "../types/token";
import { downloadText } from "../utils/download";
import {
  formatDateTimeSeconds as formatDateTime,
  formatPlainDecimal,
  formatPortfolioCurrency as formatCurrency,
  formatPortfolioKas as formatKas,
  formatPortfolioNumber as formatTokenAmount,
  formatPortfolioSignedCurrency as formatSignedCurrency,
  formatPortfolioSignedKas as formatSignedKas
} from "../utils/format";

type ChartMode = "30d" | "all";

interface HoldingRow {
  token: Token;
  balance: number;
  rawBalance: string;
  balanceIsEntryBased: boolean;
  valueKas: number | null;
  valueUsd: number | null;
  portfolioShare: number;
  avgEntryKas: number | null;
  avgEntryUsd: number | null;
  costBasisKas: number | null;
  costBasisUsd: number | null;
  pnlKas: number | null;
  pnlUsd: number | null;
  pnlPercent: number | null;
  transactionCount: number;
}

interface PortfolioPoint {
  time: number;
  value_kas: number | null;
  value_usd: number | null;
}

interface DraftTransaction {
  type: "buy" | "sell";
  amount: string;
  price_kas: string;
  price_usd: string;
  fee_kas: string;
  fee_usd: string;
  timestamp: string;
  note: string;
}

interface WalletTokenMatch {
  token: Token;
  balance: number;
  source: WalletTokenBalance;
}

interface WalletLookupGroup {
  network: WalletNetwork;
  address: string;
  tokens: WalletTokenMatch[];
}

interface WalletLookupState {
  loading: boolean;
  error: string | null;
  groups: WalletLookupGroup[];
}

const defaultDraft = (): DraftTransaction => ({
  type: "buy",
  amount: "",
  price_kas: "",
  price_usd: "",
  fee_kas: "",
  fee_usd: "",
  timestamp: toDateTimeInputValue(new Date()),
  note: ""
});

export function PortfolioPage() {
  const portfolio = usePortfolioStore();
  const { labelDetailsFor, labelMatches } = useWalletLabels();
  const portfolioState = portfolio.state;
  const recordSnapshot = portfolio.recordSnapshot;
  const tokensState = useExplorerTokens("COMBINED");
  const tokens = tokensState.data?.tokens || [];
  const fileInputRef = useRef<HTMLInputElement>(null);
  const csvInputRef = useRef<HTMLInputElement>(null);
  const [chartMode, setChartMode] = useState<ChartMode>("30d");
  const [chartPoints, setChartPoints] = useState<PortfolioPoint[]>([]);
  const [chartLoading, setChartLoading] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);
  const [importNotice, setImportNotice] = useState<string | null>(null);
  const [expandedTokenId, setExpandedTokenId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, DraftTransaction>>({});
  const [editingTransactions, setEditingTransactions] = useState<Record<string, string | null>>({});
  const [removeCandidate, setRemoveCandidate] = useState<Token | null>(null);
  const [addQuery, setAddQuery] = useState("");
  const [walletLookup, setWalletLookup] = useState<WalletLookupState>({ loading: false, error: null, groups: [] });
  const [addedWalletBalanceKeys, setAddedWalletBalanceKeys] = useState<Set<string>>(() => new Set());

  const tokenById = useMemo(() => new Map(tokens.map((token) => [token.id, token])), [tokens]);
  const tokenBySymbol = useMemo(() => new Map(tokens.map((token) => [token.symbol.toUpperCase(), token])), [tokens]);
  const transactionsByToken = useMemo(() => groupTransactions(portfolioState.transactions), [portfolioState.transactions]);
  const portfolioTokens = useMemo(() => {
    const ids = new Set<string>();
    for (const tokenId of Object.keys(portfolioState.balances)) {
      ids.add(tokenId);
    }
    for (const tokenId of transactionsByToken.keys()) {
      ids.add(tokenId);
    }
    return Array.from(ids).map((id) => tokenById.get(id)).filter((token): token is Token => Boolean(token));
  }, [portfolioState.balances, tokenById, transactionsByToken]);
  const rows = useMemo(() => buildRows(portfolioTokens, portfolioState.balances, transactionsByToken), [portfolioTokens, portfolioState.balances, transactionsByToken]);
  const portfolioTokenIds = useMemo(() => new Set(rows.map((row) => row.token.id)), [rows]);
  const holdings = useMemo(() => rows.filter((row) => row.balance > 0), [rows]);
  const totals = useMemo(() => summarizeRows(holdings), [holdings]);
  const change24h = useMemo(() => estimateWeightedChange(holdings, "price_change_24h_percent"), [holdings]);
  const movers = useMemo(() => buildMovers(holdings), [holdings]);
  const bestHolding = useMemo(() => bestByPnl(holdings), [holdings]);
  const worstHolding = useMemo(() => worstByPnl(holdings), [holdings]);
  const addSearchTokens = useMemo(() => {
    const normalized = addQuery.trim().toLowerCase();
    if (!normalized || isWalletQuery(addQuery)) {
      return [];
    }
    return tokens
      .filter((token) => token.layer === "KRC20" || token.layer === "KCC20" || token.layer === "L2")
      .filter((token) => token.symbol.toLowerCase().includes(normalized) || token.name.toLowerCase().includes(normalized))
      .slice(0, 12);
  }, [addQuery, tokens]);
  const addLabelMatches = useMemo(() => labelMatches(addQuery), [addQuery, labelMatches]);

  useEffect(() => {
    if (!tokensState.loading && holdings.length > 0) {
      recordSnapshot(totals.valueKas, totals.valueUsd);
    }
  }, [holdings.length, recordSnapshot, tokensState.loading, totals.valueKas, totals.valueUsd]);

  useEffect(() => {
    let active = true;
    if (chartMode === "all") {
      setChartPoints(portfolioState.snapshots.map((snapshot) => ({
        time: Math.floor(Date.parse(snapshot.timestamp) / 1000),
        value_kas: snapshot.value_kas,
        value_usd: snapshot.value_usd
      })).filter((point) => Number.isFinite(point.time)));
      return () => {
        active = false;
      };
    }

    if (holdings.length === 0) {
      setChartPoints([]);
      return () => {
        active = false;
      };
    }

    setChartLoading(true);
    Promise.all(holdings.map(async (row) => {
      try {
        const chart = await getChart(row.token.id, "30d");
        return { row, points: chart.data.points };
      } catch {
        return { row, points: [] as ChartPoint[] };
      }
    })).then((series) => {
      if (!active) return;
      setChartPoints(buildPortfolioChart(series));
    }).finally(() => {
      if (active) setChartLoading(false);
    });

    return () => {
      active = false;
    };
  }, [chartMode, holdings, portfolioState.snapshots]);

  function exportJson() {
    downloadText("kaspa-token-portfolio.json", portfolio.exportPortfolio(), "application/json");
  }

  function exportCsv() {
    downloadText("kaspa-token-portfolio-transactions.csv", buildTransactionsCsv(portfolioState.transactions, tokenById), "text/csv;charset=utf-8");
  }

  async function importJson(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      portfolio.importPortfolio(await file.text());
      setImportError(null);
      setImportNotice("Portfolio imported.");
    } catch (error) {
      setImportError(error instanceof Error ? error.message : "Import failed");
      setImportNotice(null);
    } finally {
      event.target.value = "";
    }
  }

  async function importCsv(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      const transactions = parseTransactionsCsv(await file.text(), tokenById, tokenBySymbol);
      const imported = portfolio.importTransactions(transactions);
      setImportError(null);
      setImportNotice(imported > 0 ? `Imported ${imported} transaction${imported === 1 ? "" : "s"}.` : "No new transactions imported.");
    } catch (error) {
      setImportError(error instanceof Error ? error.message : "CSV import failed");
      setImportNotice(null);
    } finally {
      event.target.value = "";
    }
  }

  function setDraftValue(tokenId: string, field: keyof DraftTransaction, value: string) {
    setDrafts((current) => ({ ...current, [tokenId]: { ...(current[tokenId] || defaultDraft()), [field]: value } }));
  }

  function ensureDraft(token: Token) {
    setDrafts((current) => {
      if (current[token.id]) return current;
      return {
        ...current,
        [token.id]: {
          ...defaultDraft(),
          price_kas: token.price_kas !== null ? String(token.price_kas) : "",
          price_usd: token.price_usd !== null ? String(token.price_usd) : ""
        }
      };
    });
  }

  function toggleLots(token: Token) {
    setExpandedTokenId((current) => current === token.id ? null : token.id);
    ensureDraft(token);
  }

  function addLot(event: FormEvent<HTMLFormElement>, tokenId: string) {
    event.preventDefault();
    const draft = drafts[tokenId] || defaultDraft();
    if (parseNumber(draft.amount) <= 0) return;
    const transaction: Omit<PortfolioTransaction, "id"> = {
      token_id: tokenId,
      type: draft.type,
      amount: draft.amount,
      price_kas: draft.price_kas,
      price_usd: draft.price_usd,
      fee_kas: draft.fee_kas,
      fee_usd: draft.fee_usd,
      timestamp: new Date(draft.timestamp || Date.now()).toISOString(),
      note: draft.note
    };
    const editingId = editingTransactions[tokenId];
    if (editingId) {
      portfolio.updateTransaction(editingId, transaction);
    } else {
      portfolio.addTransaction(transaction);
    }
    setDrafts((current) => ({ ...current, [tokenId]: { ...defaultDraft(), type: draft.type, price_kas: draft.price_kas, price_usd: draft.price_usd } }));
    setEditingTransactions((current) => ({ ...current, [tokenId]: null }));
  }

  function editLot(token: Token, transaction: PortfolioTransaction) {
    ensureDraft(token);
    setExpandedTokenId(token.id);
    setEditingTransactions((current) => ({ ...current, [token.id]: transaction.id }));
    setDrafts((current) => ({
      ...current,
      [token.id]: {
        type: transaction.type,
        amount: transaction.amount,
        price_kas: displayEditableNumber(transaction.price_kas),
        price_usd: displayEditableNumber(transaction.price_usd),
        fee_kas: displayEditableNumber(transaction.fee_kas),
        fee_usd: displayEditableNumber(transaction.fee_usd),
        timestamp: toDateTimeInputValue(new Date(transaction.timestamp)),
        note: transaction.note || ""
      }
    }));
  }

  function cancelEdit(tokenId: string) {
    setEditingTransactions((current) => ({ ...current, [tokenId]: null }));
    setDrafts((current) => ({ ...current, [tokenId]: defaultDraft() }));
  }

  function addTokenToPortfolio(token: Token, balance = "", mode: "set" | "add" = "set") {
    if (mode === "add") {
      portfolio.addBalance(token.id, balance);
      return;
    }
    const numericBalance = balance ? Number(balance) : null;
    const formattedBalance = numericBalance !== null && Number.isFinite(numericBalance) && numericBalance > 0
      ? formatInputBalance(numericBalance, true)
      : balance;
    portfolio.setBalance(token.id, formattedBalance || portfolioState.balances[token.id] || "");
  }

  function addWalletTokenToPortfolio(key: string, token: Token, balance: string, mode: "set" | "add") {
    addTokenToPortfolio(token, balance, mode);
    setAddedWalletBalanceKeys((current) => {
      const next = new Set(current);
      next.add(key);
      return next;
    });
  }

  function addWalletGroupToPortfolio(group: WalletLookupGroup) {
    setAddedWalletBalanceKeys((current) => {
      const next = new Set(current);
      for (const item of group.tokens) {
        const key = walletBalanceKey(group, item);
        if (next.has(key)) {
          continue;
        }
        addTokenToPortfolio(item.token, String(item.balance), portfolioTokenIds.has(item.token.id) ? "add" : "set");
        next.add(key);
      }
      return next;
    });
  }

  async function lookupWallet(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const query = addQuery.trim();
    const matchedLabels = labelMatches(query);
    const targets = matchedLabels.length > 0
      ? matchedLabels.flatMap((match) => walletTargetsForAddress(match.address))
      : isWalletQuery(query) ? walletTargetsForAddress(query) : [];
    if (targets.length === 0) return;
    setAddedWalletBalanceKeys(new Set());
    setWalletLookup({ loading: true, error: null, groups: [] });
    try {
      const uniqueTargets = Array.from(new Map(targets.map((target) => [`${target.network}:${target.address.toLowerCase()}`, target])).values());
      const results = await Promise.all(uniqueTargets.map(async ({ network, address }) => ({ network, queryAddress: address, envelope: await getWallet(network, address) })));
      const groups = results.map(({ network, envelope }) => ({
        network,
        address: envelope.data.address,
        tokens: envelope.data.tokens
          .map((balance) => resolveWalletToken(balance, network, tokenById, tokenBySymbol, tokens))
          .filter((item): item is WalletTokenMatch => Boolean(item))
      })).filter((group) => group.tokens.length > 0);
      setWalletLookup({ loading: false, error: null, groups });
    } catch (error) {
      setWalletLookup({ loading: false, error: error instanceof Error ? error.message : "Wallet lookup failed", groups: [] });
    }
  }

  if (tokensState.loading) {
    return <LoadingState />;
  }

  return (
    <section>
      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="text-sm font-bold text-kaspa-primary">Portfolio</div>
          <h1 className="mt-1 text-3xl font-bold text-kaspa-text">Portfolio</h1>
        </div>
        <div className="flex flex-wrap gap-2">
          <button onClick={exportJson} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-border bg-kaspa-card px-3 text-sm font-bold text-kaspa-text hover:border-kaspa-primary hover:text-kaspa-primary">
            <Download className="h-4 w-4" aria-hidden="true" /> Export Portfolio
          </button>
          <button onClick={() => fileInputRef.current?.click()} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-border bg-kaspa-card px-3 text-sm font-bold text-kaspa-text hover:border-kaspa-primary hover:text-kaspa-primary">
            <Upload className="h-4 w-4" aria-hidden="true" /> Import Portfolio
          </button>
          <button onClick={exportCsv} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-primary/60 bg-kaspa-primary/10 px-3 text-sm font-bold text-kaspa-primary hover:border-kaspa-primary">
            <Download className="h-4 w-4" aria-hidden="true" /> Export Transaction CSV
          </button>
          <button onClick={() => csvInputRef.current?.click()} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-primary/60 bg-kaspa-primary/10 px-3 text-sm font-bold text-kaspa-primary hover:border-kaspa-primary">
            <Upload className="h-4 w-4" aria-hidden="true" /> Import Transaction CSV
          </button>
          <input ref={fileInputRef} type="file" accept="application/json,.json" onChange={importJson} className="hidden" />
          <input ref={csvInputRef} type="file" accept="text/csv,.csv" onChange={importCsv} className="hidden" />
        </div>
      </div>

      {importError ? <div className="mb-4 rounded-md border border-red-400/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{importError}</div> : null}
      {importNotice ? <div className="mb-4 rounded-md border border-kaspa-primary/50 bg-kaspa-primary/10 px-4 py-3 text-sm text-kaspa-primary">{importNotice}</div> : null}
      {tokensState.error ? <EmptyState title="API unavailable" body={tokensState.error} /> : null}

      <div className="mx-auto mb-6 flex max-w-4xl gap-3 rounded-md border border-amber-300/60 bg-amber-300/10 px-4 py-3 text-sm text-amber-100 shadow-[0_0_18px_rgba(252,211,77,0.12)]">
        <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-200" aria-hidden="true" />
        <div>
          <div className="font-bold text-amber-100">Remember to export your portfolio data</div>
          <div className="mt-1 text-amber-100/85">Remember to export your portfolio data so you can always import again after clearing your cache. Your portfolio is only stored locally on your device, not on our server.</div>
        </div>
      </div>

      <div className="mb-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-7">
        <MetricTile label="Total KAS" value={formatKas(totals.valueKas)} tone="primary" />
        <MetricTile label="Total USD" value={formatCurrency(totals.valueUsd)} />
        <MetricTile label="PnL KAS" value={formatSignedKas(totals.pnlKas)} tone={totals.pnlKas !== null && totals.pnlKas >= 0 ? "primary" : "normal"} />
        <MetricTile label="PnL USD" value={formatSignedCurrency(totals.pnlUsd)} tone={totals.pnlUsd !== null && totals.pnlUsd >= 0 ? "primary" : "normal"} />
        <MetricTile label="24h Change" value={<DirectionalPercent value={change24h} />} tone={change24h !== null && change24h >= 0 ? "primary" : "normal"} />
        <MetricTile label="Best Holding" value={bestHolding ? <>{bestHolding.token.symbol} <DirectionalPercent value={bestHolding.pnlPercent} /></> : "n/a"} />
        <MetricTile label="Worst Holding" value={worstHolding ? <>{worstHolding.token.symbol} <DirectionalPercent value={worstHolding.pnlPercent} /></> : "n/a"} />
      </div>

      <div className="mb-6 grid gap-4 xl:grid-cols-[minmax(0,1.5fr)_minmax(320px,0.8fr)]">
        <div className="kaspa-panel rounded-md p-5">
          <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-lg font-bold text-kaspa-text">Portfolio Chart</h2>
            <div className="flex gap-2">
              {(["30d", "all"] as ChartMode[]).map((mode) => (
                <button key={mode} onClick={() => setChartMode(mode)} className={["focus-ring h-9 rounded-md border px-3 text-sm font-bold", chartMode === mode ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border bg-kaspa-card text-kaspa-muted"].join(" ")}>
                  {mode}
                </button>
              ))}
            </div>
          </div>
          {chartLoading ? <div className="h-72 animate-pulse rounded-md border border-kaspa-border bg-kaspa-background" /> : <PortfolioChart points={chartPoints} />}
        </div>
        <AllocationPie rows={holdings} />
      </div>

      <MovementPanel movers={movers} />

      <AddPortfolioTokenPanel
        query={addQuery}
        searchTokens={addSearchTokens}
        walletLookup={walletLookup}
        labelMatches={addLabelMatches}
        addedTokenIds={portfolioTokenIds}
        addedWalletBalanceKeys={addedWalletBalanceKeys}
        onQuery={setAddQuery}
        onWalletLookup={lookupWallet}
        onAdd={addTokenToPortfolio}
        onAddWalletBalance={addWalletTokenToPortfolio}
        onAddWalletGroup={addWalletGroupToPortfolio}
        labelDetailsFor={labelDetailsFor}
      />

      {rows.length === 0 ? (
        <EmptyState title="No portfolio entries yet" body="Add a balance or transaction to track real holdings here. Favorites are managed separately as a watchlist." />
      ) : (
        <PortfolioTable
          title="Portfolio"
          rows={rows}
          balances={portfolioState.balances}
          transactionsByToken={transactionsByToken}
          expandedTokenId={expandedTokenId}
          drafts={drafts}
          onBalance={portfolio.setBalance}
          onRemove={(tokenId) => setRemoveCandidate(tokenById.get(tokenId) || null)}
          onToggleLots={toggleLots}
          onDraft={setDraftValue}
          onAddLot={addLot}
          editingTransactionId={editingTransactions}
          onEditTransaction={editLot}
          onCancelEdit={cancelEdit}
          onRemoveTransaction={portfolio.removeTransaction}
        />
      )}
      <RemoveTokenModal
        token={removeCandidate}
        onCancel={() => setRemoveCandidate(null)}
        onConfirm={() => {
          if (!removeCandidate) return;
          portfolio.removeToken(removeCandidate.id);
          setRemoveCandidate(null);
        }}
      />
    </section>
  );
}

function buildRows(tokens: Token[], balances: Record<string, string>, transactionsByToken: Map<string, PortfolioTransaction[]>): HoldingRow[] {
  const rows = tokens.map((token) => {
    const rawBalance = balances[token.id] || "";
    const manualBalance = numericBalance(rawBalance);
    const transactions = transactionsByToken.get(token.id) || [];
    const entryBalance = calculateEntryBalance(transactions);
    const balanceIsEntryBased = transactions.length > 0;
    const balance = balanceIsEntryBased ? Math.max(0, entryBalance) + manualBalance : manualBalance;
    const valueKas = token.price_kas !== null ? balance * token.price_kas : null;
    const valueUsd = token.price_usd !== null ? balance * token.price_usd : null;
    const basis = calculateCostBasis(balance, transactions);
    const pnlUsd = basis.costBasisUsd !== null && valueUsd !== null ? valueUsd - basis.costBasisUsd : null;
    const currentKasUsd = token.price_kas !== null && token.price_kas > 0 && token.price_usd !== null
      ? token.price_usd / token.price_kas
      : null;
    const pnlKas = pnlUsd !== null && currentKasUsd !== null && Number.isFinite(currentKasUsd) && currentKasUsd > 0
      ? pnlUsd / currentKasUsd
      : basis.costBasisKas !== null && valueKas !== null
        ? valueKas - basis.costBasisKas
        : null;
    const pnlPercent = basis.costBasisUsd && pnlUsd !== null ? pnlUsd / basis.costBasisUsd * 100 : basis.costBasisKas && pnlKas !== null ? pnlKas / basis.costBasisKas * 100 : null;
    return {
      token,
      balance,
      rawBalance,
      balanceIsEntryBased,
      valueKas,
      valueUsd,
      portfolioShare: 0,
      avgEntryKas: basis.avgEntryKas,
      avgEntryUsd: basis.avgEntryUsd,
      costBasisKas: basis.costBasisKas,
      costBasisUsd: basis.costBasisUsd,
      pnlKas,
      pnlUsd,
      pnlPercent,
      transactionCount: (transactionsByToken.get(token.id) || []).length
    };
  });
  const totalUsd = rows.reduce((sum, row) => sum + (row.valueUsd || 0), 0);
  const totalKas = rows.reduce((sum, row) => sum + (row.valueKas || 0), 0);
  return rows.map((row) => ({
    ...row,
    portfolioShare: totalUsd > 0 && row.valueUsd !== null ? row.valueUsd / totalUsd * 100 : totalKas > 0 && row.valueKas !== null ? row.valueKas / totalKas * 100 : 0
  }));
}

function calculateEntryBalance(transactions: PortfolioTransaction[]) {
  return transactions.reduce((sum, transaction) => {
    const amount = parseNumber(transaction.amount);
    return sum + (transaction.type === "buy" ? amount : -amount);
  }, 0);
}

function calculateCostBasis(balance: number, transactions: PortfolioTransaction[]) {
  let netAmountKas = 0;
  let netAmountUsd = 0;
  let costKas = 0;
  let costUsd = 0;
  for (const transaction of transactions) {
    const amount = parseNumber(transaction.amount);
    if (amount <= 0 || transaction.type !== "buy") continue;
    const priceKas = parseOptionalNumber(transaction.price_kas);
    const priceUsd = parseOptionalNumber(transaction.price_usd);
    if (priceKas !== null) {
      netAmountKas += amount;
      costKas += amount * priceKas + (parseOptionalNumber(transaction.fee_kas) || 0);
    }
    if (priceUsd !== null) {
      netAmountUsd += amount;
      costUsd += amount * priceUsd + (parseOptionalNumber(transaction.fee_usd) || 0);
    }
  }
  if (netAmountKas <= 0 && netAmountUsd <= 0) {
    return { avgEntryKas: null, avgEntryUsd: null, costBasisKas: null, costBasisUsd: null };
  }
  const avgEntryKas = costKas > 0 && netAmountKas > 0 ? costKas / netAmountKas : null;
  const avgEntryUsd = costUsd > 0 && netAmountUsd > 0 ? costUsd / netAmountUsd : null;
  return {
    avgEntryKas,
    avgEntryUsd,
    costBasisKas: avgEntryKas !== null && balance > 0 ? avgEntryKas * balance : null,
    costBasisUsd: avgEntryUsd !== null && balance > 0 ? avgEntryUsd * balance : null
  };
}

function groupTransactions(transactions: PortfolioTransaction[]) {
  const grouped = new Map<string, PortfolioTransaction[]>();
  for (const transaction of transactions) {
    const current = grouped.get(transaction.token_id) || [];
    current.push(transaction);
    grouped.set(transaction.token_id, current);
  }
  for (const [tokenId, items] of grouped) {
    grouped.set(tokenId, items.sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp)));
  }
  return grouped;
}

function summarizeRows(rows: HoldingRow[]) {
  return rows.reduce((acc, row) => ({
    valueKas: addNullable(acc.valueKas, row.valueKas),
    valueUsd: addNullable(acc.valueUsd, row.valueUsd),
    pnlKas: addNullable(acc.pnlKas, row.pnlKas),
    pnlUsd: addNullable(acc.pnlUsd, row.pnlUsd)
  }), { valueKas: null as number | null, valueUsd: null as number | null, pnlKas: null as number | null, pnlUsd: null as number | null });
}

function addNullable(current: number | null, value: number | null) {
  if (value === null) return current;
  return (current || 0) + value;
}

function estimateWeightedChange(rows: HoldingRow[], field: "price_change_24h_percent") {
  let currentValue = 0;
  let previousValue = 0;
  for (const row of rows) {
    const change = row.token[field];
    if (typeof change === "number" && Number.isFinite(change) && row.valueUsd !== null) {
      const previous = valueBeforePercentChange(row.valueUsd, change);
      if (previous !== null) {
        currentValue += row.valueUsd;
        previousValue += previous;
      }
    }
  }
  return previousValue > 0 ? (currentValue - previousValue) / previousValue * 100 : null;
}

function buildMovers(rows: HoldingRow[]) {
  return rows.map((row) => {
    const change = row.token.price_change_24h_percent;
    const previousUsd = change !== null && row.valueUsd !== null ? valueBeforePercentChange(row.valueUsd, change) : null;
    const previousKas = change !== null && row.valueKas !== null ? valueBeforePercentChange(row.valueKas, change) : null;
    const impactUsd = previousUsd !== null && row.valueUsd !== null ? row.valueUsd - previousUsd : null;
    const impactKas = previousKas !== null && row.valueKas !== null ? row.valueKas - previousKas : null;
    return { row, change, impactUsd, impactKas };
  }).filter((item) => {
    if (item.change === null) {
      return false;
    }
    const impact = Math.abs(item.impactUsd ?? item.impactKas ?? 0);
    return impact > 0;
  }).sort((a, b) => Math.abs(b.impactUsd ?? b.impactKas ?? 0) - Math.abs(a.impactUsd ?? a.impactKas ?? 0));
}

function valueBeforePercentChange(currentValue: number, changePercent: number) {
  const multiplier = 1 + changePercent / 100;
  if (!Number.isFinite(currentValue) || !Number.isFinite(multiplier) || multiplier <= 0) {
    return null;
  }
  return currentValue / multiplier;
}

function AddPortfolioTokenPanel({ query, searchTokens, walletLookup, labelMatches, addedTokenIds, addedWalletBalanceKeys, onQuery, onWalletLookup, onAdd, onAddWalletBalance, onAddWalletGroup, labelDetailsFor }: {
  query: string;
  searchTokens: Token[];
  walletLookup: WalletLookupState;
  labelMatches: WalletLabelMatch[];
  addedTokenIds: Set<string>;
  addedWalletBalanceKeys: Set<string>;
  onQuery: (value: string) => void;
  onWalletLookup: (event: FormEvent<HTMLFormElement>) => void;
  onAdd: (token: Token, balance?: string, mode?: "set" | "add") => void;
  onAddWalletBalance: (key: string, token: Token, balance: string, mode: "set" | "add") => void;
  onAddWalletGroup: (group: WalletLookupGroup) => void;
  labelDetailsFor: (address: string | undefined | null) => ResolvedWalletLabel | null;
}) {
  const walletMode = isWalletQuery(query) || labelMatches.length > 0;
  return (
    <div className="kaspa-panel mb-6 rounded-md p-5">
      <div className="mb-4">
        <h2 className="text-lg font-bold text-kaspa-text">Add token to portfolio</h2>
        <p className="mt-1 text-sm text-kaspa-muted">Search KRC20/KCC20/L2 tickers manually, enter a wallet, or type a saved/global wallet label to scan detected holdings.</p>
      </div>
      <form onSubmit={onWalletLookup} className="flex flex-col gap-2 md:flex-row">
        <div className="relative min-w-0 flex-1">
          <input
            value={query}
            onChange={(event) => onQuery(event.target.value)}
            placeholder="Search ticker or enter wallet"
            className="h-11 w-full min-w-0 rounded-md border border-kaspa-border bg-kaspa-background px-3 pr-11 text-sm font-semibold text-kaspa-text outline-none focus:border-kaspa-primary"
          />
          {query ? (
            <button
              type="button"
              onClick={() => onQuery("")}
              title="Clear"
              aria-label="Clear portfolio search"
              className="focus-ring absolute right-2 top-1/2 flex h-7 w-7 -translate-y-1/2 items-center justify-center rounded-md border border-kaspa-border bg-kaspa-card text-kaspa-muted transition hover:border-kaspa-primary/70 hover:text-kaspa-primary"
            >
              <X className="h-3.5 w-3.5" aria-hidden="true" />
            </button>
          ) : null}
        </div>
        <button
          type="submit"
          disabled={!walletMode || walletLookup.loading}
          className="focus-ring h-11 rounded-md border border-kaspa-primary/60 px-4 text-sm font-bold text-kaspa-primary disabled:cursor-not-allowed disabled:opacity-40"
        >
          {walletLookup.loading ? "Scanning..." : "Scan wallet"}
        </button>
      </form>

      {!walletMode && query.trim() ? (
        <div className="mt-4 grid gap-2 md:grid-cols-2">
          {searchTokens.map((token) => (
            <TokenAddRow key={token.id} token={token} added={addedTokenIds.has(token.id)} onAdd={() => onAdd(token)} />
          ))}
          {searchTokens.length === 0 ? <div className="rounded-md border border-kaspa-border bg-kaspa-background px-4 py-3 text-sm text-kaspa-muted">No matching KRC20, KCC20, or L2 token found.</div> : null}
        </div>
      ) : null}

      {labelMatches.length > 0 ? (
        <div className="mt-4 rounded-md border border-kaspa-primary/40 bg-kaspa-primary/5 p-3">
          <div className="mb-2 text-xs font-bold text-kaspa-primary">Matched wallet label{labelMatches.length === 1 ? "" : "s"}</div>
          <div className="grid gap-2 md:grid-cols-2">
            {labelMatches.map((match) => (
              <button
                key={`${match.source}:${match.address}`}
                type="button"
                onClick={() => onQuery(match.address)}
                className="focus-ring rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2 text-left transition hover:border-kaspa-primary/70"
              >
                <div className="font-bold text-kaspa-text">{match.label} <span className="text-[10px] text-kaspa-muted">({match.source})</span></div>
                <div className="mt-1 break-all font-mono text-[11px] text-kaspa-muted">{match.address}</div>
              </button>
            ))}
          </div>
          <div className="mt-2 text-xs text-kaspa-muted">Press Scan wallet to scan all matched addresses, or click one address to scan only that wallet.</div>
        </div>
      ) : null}

      {walletLookup.error ? <div className="mt-4 rounded-md border border-red-300/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{walletLookup.error}</div> : null}
      {walletLookup.groups.length > 0 ? (
        <div className="mt-5 space-y-4">
          {walletLookup.groups.map((group) => {
            const pendingCount = group.tokens.filter((item) => !addedWalletBalanceKeys.has(walletBalanceKey(group, item))).length;
            const groupLabel = labelDetailsFor(group.address);
            return (
            <div key={group.network + group.address}>
              <div className="mb-2 flex flex-col gap-2 lg:flex-row lg:items-center">
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <h3 className="text-sm font-bold text-kaspa-primary">{networkLabel(group.network)}</h3>
                  {groupLabel ? <WalletLabelBadge label={groupLabel} compact /> : null}
                  <span className="break-all font-mono text-[11px] text-kaspa-muted">{group.address}</span>
                </div>
                <div className="hidden h-px flex-1 bg-kaspa-border lg:block" />
                <div className="flex items-center gap-3">
                  <span className="text-xs font-semibold text-kaspa-muted">{group.tokens.length} token{group.tokens.length === 1 ? "" : "s"}</span>
                  {group.tokens.length > 1 ? (
                    <button
                      type="button"
                      onClick={() => onAddWalletGroup(group)}
                      disabled={pendingCount === 0}
                      className="focus-ring h-8 rounded-md border border-kaspa-primary/60 px-3 text-xs font-bold text-kaspa-primary disabled:cursor-not-allowed disabled:border-kaspa-border disabled:text-kaspa-muted disabled:opacity-60"
                    >
                      {pendingCount === 0 ? "All Added" : "Add All"}
                    </button>
                  ) : null}
                </div>
              </div>
              <div className="grid gap-2 md:grid-cols-2">
                {group.tokens.map((item) => {
                  const rowKey = walletBalanceKey(group, item);
                  const tokenAlreadyAdded = addedTokenIds.has(item.token.id);
                  const balanceAddedFromScan = addedWalletBalanceKeys.has(rowKey);
                  return (
                    <TokenAddRow
                      key={rowKey}
                      token={item.token}
                      balance={item.balance}
                      added={tokenAlreadyAdded || balanceAddedFromScan}
                      allowAddBalance={tokenAlreadyAdded && !balanceAddedFromScan}
                      onAdd={() => onAddWalletBalance(rowKey, item.token, String(item.balance), tokenAlreadyAdded ? "add" : "set")}
                    />
                  );
                })}
              </div>
            </div>
          );
          })}
        </div>
      ) : null}
      {!walletLookup.loading && walletMode && walletLookup.groups.length === 0 && !walletLookup.error ? (
        <div className="mt-4 rounded-md border border-kaspa-border bg-kaspa-background px-4 py-3 text-sm text-kaspa-muted">Enter a wallet and scan to import holdings.</div>
      ) : null}
    </div>
  );
}

function walletBalanceKey(group: WalletLookupGroup, item: WalletTokenMatch) {
  return [group.network, group.address.toLowerCase(), item.token.id, item.balance].join(":");
}

function TokenAddRow({ token, balance, added, allowAddBalance, onAdd }: { token: Token; balance?: number; added?: boolean; allowAddBalance?: boolean; onAdd: () => void }) {
  const canAddBalance = Boolean(added && allowAddBalance && balance !== undefined && balance > 0);
  return (
    <div className="flex items-center gap-3 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-3">
      <TokenLogo src={token.image_url} symbol={token.symbol} size="sm" />
      <div className="min-w-0 flex-1">
        <div className="truncate font-bold text-kaspa-text">{token.symbol}</div>
        <div className="text-xs font-semibold text-kaspa-muted">{token.layer}{balance !== undefined ? ` · Balance ${formatTokenAmount(balance)}` : ""}</div>
      </div>
      <button
        onClick={onAdd}
        disabled={added && !canAddBalance}
        className="focus-ring h-9 rounded-md border border-kaspa-primary/60 px-3 text-xs font-bold text-kaspa-primary disabled:cursor-not-allowed disabled:border-kaspa-border disabled:text-kaspa-muted disabled:opacity-60"
      >
        {canAddBalance ? "Add Balance" : added ? "Added" : "Add"}
      </button>
    </div>
  );
}

function isWalletQuery(value: string) {
  const trimmed = value.trim();
  return trimmed.startsWith("kaspa:") || /^[a-z0-9-]+\.kas$/i.test(trimmed) || /^0x[a-fA-F0-9]{40}$/.test(trimmed);
}

function walletNetworksForQuery(value: string): WalletNetwork[] {
  return /^0x[a-fA-F0-9]{40}$/.test(value.trim()) ? ["kasplex", "igra"] : ["krc20"];
}

function walletTargetsForAddress(address: string): Array<{ network: WalletNetwork; address: string }> {
  return walletNetworksForQuery(address).map((network) => ({ network, address }));
}

function resolveWalletToken(balance: WalletTokenBalance, network: WalletNetwork, tokenById: Map<string, Token>, _tokenBySymbol: Map<string, Token>, tokens: Token[]): WalletTokenMatch | null {
  if(balance.balance===null)return null;
  const tokenFromId = balance.token_id ? tokenById.get(balance.token_id) : null;
  const preferredLayer = balance.token_id?.startsWith("kcc20-")?"KCC20":network === "krc20" ? "KRC20" : "L2";
  const contract = balance.contract_address?.toLowerCase();
  const token = tokenFromId ||
    (contract ? tokens.find((item) => item.contract_address?.toLowerCase() === contract) : null) ||
    (!balance.token_id?.startsWith("kcc20-")?tokens.find((item) => item.layer === preferredLayer && item.symbol.toUpperCase() === balance.symbol.toUpperCase()):null) ||
    null;
  if (!token || (token.layer !== "KRC20" && token.layer !== "KCC20" && token.layer !== "L2")) {
    return null;
  }
  return { token, balance: balance.balance, source: balance };
}

function networkLabel(network: WalletNetwork) {
  if (network === "krc20") return "Kaspa L1";
  if (network === "kasplex") return "Kasplex L2";
  return "Igra L2";
}

function bestByPnl(rows: HoldingRow[]) {
  return rows.filter((row) => row.pnlPercent !== null).sort((a, b) => (b.pnlPercent || 0) - (a.pnlPercent || 0))[0] || null;
}

function worstByPnl(rows: HoldingRow[]) {
  return rows.filter((row) => row.pnlPercent !== null).sort((a, b) => (a.pnlPercent || 0) - (b.pnlPercent || 0))[0] || null;
}

function buildPortfolioChart(series: Array<{ row: HoldingRow; points: ChartPoint[] }>): PortfolioPoint[] {
  const byTime = new Map<number, PortfolioPoint>();
  for (const { row, points } of series) {
    for (const point of points) {
      const current = byTime.get(point.time) || { time: point.time, value_kas: null, value_usd: null };
      current.value_kas = addNullable(current.value_kas, point.price_kas !== null ? point.price_kas * row.balance : null);
      current.value_usd = addNullable(current.value_usd, point.price_usd !== null ? point.price_usd * row.balance : null);
      byTime.set(point.time, current);
    }
  }
  return [...byTime.values()].sort((a, b) => a.time - b.time);
}

function PortfolioTable({ title, rows, balances, transactionsByToken, expandedTokenId, drafts, onBalance, onRemove, onToggleLots, onDraft, onAddLot, editingTransactionId, onEditTransaction, onCancelEdit, onRemoveTransaction }: {
  title: string;
  rows: HoldingRow[];
  balances: Record<string, string>;
  transactionsByToken: Map<string, PortfolioTransaction[]>;
  expandedTokenId: string | null;
  drafts: Record<string, DraftTransaction>;
  onBalance: (tokenId: string, value: string) => void;
  onRemove: (tokenId: string) => void;
  onToggleLots: (token: Token) => void;
  onDraft: (tokenId: string, field: keyof DraftTransaction, value: string) => void;
  onAddLot: (event: FormEvent<HTMLFormElement>, tokenId: string) => void;
  editingTransactionId: Record<string, string | null>;
  onEditTransaction: (token: Token, transaction: PortfolioTransaction) => void;
  onCancelEdit: (tokenId: string) => void;
  onRemoveTransaction: (transactionId: string) => void;
}) {
  if (rows.length === 0) return null;

  return (
    <div className="kaspa-panel overflow-hidden rounded-md">
      <div className="border-b border-kaspa-border px-4 py-3">
        <h2 className="text-lg font-bold text-kaspa-text">{title}</h2>
      </div>
      <div className="divide-y divide-kaspa-border">
        {rows.map((row) => (
          <RowWithLots
            key={row.token.id}
            row={row}
            balanceValue={row.balanceIsEntryBased ? formatInputBalance(row.balance, true) : balances[row.token.id] || ""}
            transactions={transactionsByToken.get(row.token.id) || []}
            draft={drafts[row.token.id] || defaultDraft()}
            expanded={expandedTokenId === row.token.id}
            onBalance={onBalance}
            onRemove={onRemove}
            onToggleLots={onToggleLots}
            onDraft={onDraft}
            onAddLot={onAddLot}
            editingTransactionId={editingTransactionId[row.token.id] || null}
            onEditTransaction={onEditTransaction}
            onCancelEdit={onCancelEdit}
            onRemoveTransaction={onRemoveTransaction}
          />
        ))}
      </div>
    </div>
  );
}

function RowWithLots({ row, balanceValue, transactions, draft, expanded, onBalance, onRemove, onToggleLots, onDraft, onAddLot, editingTransactionId, onEditTransaction, onCancelEdit, onRemoveTransaction }: {
  row: HoldingRow;
  balanceValue: string;
  transactions: PortfolioTransaction[];
  draft: DraftTransaction;
  expanded: boolean;
  onBalance: (tokenId: string, value: string) => void;
  onRemove: (tokenId: string) => void;
  onToggleLots: (token: Token) => void;
  onDraft: (tokenId: string, field: keyof DraftTransaction, value: string) => void;
  onAddLot: (event: FormEvent<HTMLFormElement>, tokenId: string) => void;
  editingTransactionId: string | null;
  onEditTransaction: (token: Token, transaction: PortfolioTransaction) => void;
  onCancelEdit: (tokenId: string) => void;
  onRemoveTransaction: (transactionId: string) => void;
}) {
  const pnlTone = row.pnlUsd !== null && row.pnlUsd >= 0 ? "text-kaspa-primary" : "text-red-300";
  return (
    <div>
      <div className="px-4 py-4 hover:bg-kaspa-primary/5">
        <div className="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
          <Link to={row.token.layer === "KCC20" && row.token.contract_address ? "/kcc20/" + encodeURIComponent(row.token.contract_address) : "/token/" + encodeURIComponent(row.token.id)} className="focus-ring flex items-center gap-3 rounded-sm">
            <TokenLogo src={row.token.image_url} symbol={row.token.symbol} size="sm" />
            <div className="font-bold text-kaspa-text">{row.token.symbol}</div>
          </Link>
          <div className="flex flex-wrap items-center gap-2">
            <label className={["flex items-center gap-2 rounded-md border px-3 py-2", row.balanceIsEntryBased ? "border-kaspa-primary/40 bg-kaspa-primary/5" : "border-kaspa-border bg-kaspa-background"].join(" ")}>
              <span className="text-xs font-bold text-kaspa-muted">Balance</span>
              <input
                value={balanceValue}
                onChange={(event) => {
                  if (!row.balanceIsEntryBased) onBalance(row.token.id, event.target.value);
                }}
                readOnly={row.balanceIsEntryBased}
                inputMode="decimal"
                placeholder="0"
                title={row.balanceIsEntryBased ? "Balance is calculated from buy and sell entries." : "Manual balance"}
                className="h-8 w-32 bg-transparent text-right font-semibold text-kaspa-text outline-none"
              />
              <span className="text-[10px] font-bold text-kaspa-primary">{row.token.symbol}</span>
            </label>
            <button onClick={() => onToggleLots(row.token)} className={["focus-ring h-10 rounded-md border px-3 text-xs font-bold", expanded ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary"].join(" ")}>
              Add entry
            </button>
            <button
              onClick={() => onRemove(row.token.id)}
              title="Remove"
              aria-label={`Remove ${row.token.symbol}`}
              className="focus-ring inline-flex h-10 w-10 items-center justify-center rounded-md border border-kaspa-border text-kaspa-muted hover:border-red-300 hover:text-red-300"
            >
              <Trash2 className="h-4 w-4" aria-hidden="true" />
            </button>
          </div>
        </div>
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-6">
          <PortfolioMetric label="Price" value={formatKas(row.token.price_kas)} subValue={formatCurrency(row.token.price_usd)} tone="primary" />
          <PortfolioMetric label="Value" value={formatCurrency(row.valueUsd)} subValue={formatKas(row.valueKas)} />
          <PortfolioMetric label="Avg Entry" value={formatKas(row.avgEntryKas)} subValue={formatCurrency(row.avgEntryUsd)} />
          <PortfolioMetric label="PnL" value={formatSignedCurrency(row.pnlUsd)} subValue={<>{formatSignedKas(row.pnlKas)} / <DirectionalPercent value={row.pnlPercent} /></>} className={pnlTone} />
          <PortfolioMetric label="Portfolio" value={`${formatTokenAmount(row.portfolioShare)}%`} />
          <PortfolioMetric label="24h" value={<DirectionalPercent value={row.token.price_change_24h_percent} />} className={row.token.price_change_24h_percent !== null && row.token.price_change_24h_percent >= 0 ? "text-kaspa-primary" : "text-red-300"} />
        </div>
      </div>
      {expanded ? (
        <div className="bg-kaspa-background/40 px-4 py-4">
          <LotEditor row={row} transactions={transactions} draft={draft} editingTransactionId={editingTransactionId} onDraft={onDraft} onAddLot={onAddLot} onEditTransaction={onEditTransaction} onCancelEdit={onCancelEdit} onRemoveTransaction={onRemoveTransaction} />
        </div>
      ) : null}
    </div>
  );
}

function PortfolioMetric({ label, value, subValue, tone, className }: { label: string; value: ReactNode; subValue?: ReactNode; tone?: "primary"; className?: string }) {
  return (
    <div className="rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
      <div className="text-xs font-bold text-kaspa-muted">{label}</div>
      <div className={["mt-1 font-bold", tone === "primary" ? "text-kaspa-primary" : className || "text-kaspa-text"].join(" ")}>{value}</div>
      {subValue ? <div className="mt-0.5 text-xs text-kaspa-muted">{subValue}</div> : null}
    </div>
  );
}

function LotEditor({ row, transactions, draft, editingTransactionId, onDraft, onAddLot, onEditTransaction, onCancelEdit, onRemoveTransaction }: {
  row: HoldingRow;
  transactions: PortfolioTransaction[];
  draft: DraftTransaction;
  editingTransactionId: string | null;
  onDraft: (tokenId: string, field: keyof DraftTransaction, value: string) => void;
  onAddLot: (event: FormEvent<HTMLFormElement>, tokenId: string) => void;
  onEditTransaction: (token: Token, transaction: PortfolioTransaction) => void;
  onCancelEdit: (tokenId: string) => void;
  onRemoveTransaction: (transactionId: string) => void;
}) {
  return (
    <div className="rounded-md border border-kaspa-border bg-kaspa-card p-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 className="font-bold text-kaspa-text">DCA entries for {row.token.symbol}</h3>
          <p className="text-sm text-kaspa-muted">Add buy prices to calculate average entry and PnL. CSV export uses these rows.</p>
          <p className="mt-1 text-xs text-kaspa-muted">Avg KAS uses only entries with a KAS price. Empty KAS prices do not affect the average.</p>
        </div>
        <div className="rounded-md border border-kaspa-primary/50 bg-kaspa-primary/10 px-3 py-2 text-sm font-bold text-kaspa-primary">
          Avg {formatKas(row.avgEntryKas)}
        </div>
      </div>
      <form onSubmit={(event) => onAddLot(event, row.token.id)} className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <label className="block">
          <span className="mb-1 block text-xs font-bold text-kaspa-muted">Type</span>
          <select value={draft.type} onChange={(event) => onDraft(row.token.id, "type", event.target.value)} className="h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background px-3 text-sm font-semibold text-kaspa-text outline-none focus:border-kaspa-primary">
            <option value="buy">Buy</option>
            <option value="sell">Sell</option>
          </select>
        </label>
        <PortfolioInput label="Token amount" value={draft.amount} onChange={(value) => onDraft(row.token.id, "amount", value)} />
        <PortfolioInput label="Entry price in KAS" value={draft.price_kas} onChange={(value) => onDraft(row.token.id, "price_kas", value)} />
        <PortfolioInput label="Entry price in USD" value={draft.price_usd} onChange={(value) => onDraft(row.token.id, "price_usd", value)} />
        <PortfolioInput label="Fee in KAS" value={draft.fee_kas} onChange={(value) => onDraft(row.token.id, "fee_kas", value)} />
        <PortfolioInput label="Fee in USD" value={draft.fee_usd} onChange={(value) => onDraft(row.token.id, "fee_usd", value)} />
        <label className="block md:col-span-2">
          <span className="mb-1 block text-xs font-bold text-kaspa-muted">Date</span>
          <input type="datetime-local" step="1" value={draft.timestamp} onChange={(event) => onDraft(row.token.id, "timestamp", event.target.value)} className="h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background px-3 text-sm text-kaspa-text outline-none focus:border-kaspa-primary" />
        </label>
        <label className="block md:col-span-2 xl:col-span-3">
          <span className="mb-1 block text-xs font-bold text-kaspa-muted">Note</span>
          <input value={draft.note} onChange={(event) => onDraft(row.token.id, "note", event.target.value)} placeholder="Optional note" className="h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background px-3 text-sm text-kaspa-text outline-none focus:border-kaspa-primary" />
        </label>
        <div className="flex items-end">
          <button className="focus-ring h-11 w-full rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary shadow-[0_0_12px_rgba(0,255,208,0.18)] hover:bg-kaspa-primary/20">
            {editingTransactionId ? "Save entry" : "Add entry"}
          </button>
        </div>
        {editingTransactionId ? (
          <div className="flex items-end">
            <button type="button" onClick={() => onCancelEdit(row.token.id)} className="focus-ring h-11 w-full rounded-md border border-kaspa-border px-4 text-sm font-bold text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
              Cancel edit
            </button>
          </div>
        ) : null}
      </form>
      <div className="mt-4 overflow-x-auto">
        {transactions.length === 0 ? (
          <div className="rounded-md border border-kaspa-border bg-kaspa-background px-4 py-3 text-sm text-kaspa-muted">No entries yet.</div>
        ) : (
          <div className="explorer-card-grid grid gap-3 sm:grid-cols-2">
              {transactions.map((transaction) => {
                const amount = parseNumber(transaction.amount);
                const priceKas = parseOptionalNumber(transaction.price_kas);
                const priceUsd = parseOptionalNumber(transaction.price_usd);
                const feeUsd = parseOptionalNumber(transaction.fee_usd) || 0;
                const totalUsd = priceUsd !== null ? amount * priceUsd + feeUsd : null;
                return (
                  <article key={transaction.id} className={"min-w-0 rounded-md border border-kaspa-border p-4 " + (editingTransactionId === transaction.id ? "bg-kaspa-primary/5" : "")}><dl className="explorer-facts space-y-3">
                    <div><dt>Date</dt><dd>{formatDateTime(transaction.timestamp)}</dd></div>
                    <div><dt>Type</dt><dd>{transaction.type}</dd></div>
                    <div><dt>Amount</dt><dd>{formatTokenAmount(amount)}</dd></div>
                    <div><dt>Price KAS</dt><dd>{formatKas(priceKas)}</dd></div>
                    <div><dt>Price USD</dt><dd>{formatCurrency(priceUsd)}</dd></div>
                    <div><dt>Total USD</dt><dd>{formatCurrency(totalUsd)}</dd></div>
                    </dl><div className="mt-3">
                      <div className="flex justify-end gap-2">
                        <button onClick={() => onEditTransaction(row.token, transaction)} title="Edit" aria-label={`Edit ${row.token.symbol} entry`} className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-kaspa-border text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
                          <Pencil className="h-4 w-4" aria-hidden="true" />
                        </button>
                        <button onClick={() => onRemoveTransaction(transaction.id)} title="Remove" aria-label={`Remove ${row.token.symbol} entry`} className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-kaspa-border text-kaspa-muted hover:border-red-300 hover:text-red-300">
                          <Trash2 className="h-4 w-4" aria-hidden="true" />
                        </button>
                      </div>
                    </div>
                  </article>
                );
              })}
          </div>
        )}
      </div>
    </div>
  );
}

function RemoveTokenModal({ token, onCancel, onConfirm }: { token: Token | null; onCancel: () => void; onConfirm: () => void }) {
  if (!token) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-kaspa-background/80 px-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="remove-token-title">
      <div className="kaspa-panel w-full max-w-md rounded-md p-5 shadow-[0_20px_80px_rgba(0,0,0,0.45)]">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-red-300/50 bg-red-400/10 text-red-300">
            <AlertTriangle className="h-5 w-5" aria-hidden="true" />
          </div>
          <div className="min-w-0">
            <h2 id="remove-token-title" className="text-lg font-bold text-kaspa-text">Remove {token.symbol}?</h2>
            <p className="mt-2 text-sm leading-6 text-kaspa-muted">
              This removes the token from your portfolio and deletes all portfolio entries for this token. Favorites are not affected.
            </p>
          </div>
        </div>
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button onClick={onCancel} className="focus-ring h-10 rounded-md border border-kaspa-border px-4 text-sm font-bold text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
            Cancel
          </button>
          <button onClick={onConfirm} className="focus-ring inline-flex h-10 items-center justify-center gap-2 rounded-md border border-red-300/70 bg-red-400/10 px-4 text-sm font-bold text-red-200 hover:bg-red-400/20">
            <Trash2 className="h-4 w-4" aria-hidden="true" /> Remove
          </button>
        </div>
      </div>
    </div>
  );
}

function PortfolioInput({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-bold text-kaspa-muted">{label}</span>
      <input value={value} onChange={(event) => onChange(event.target.value)} inputMode="decimal" placeholder="0" className="h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background px-3 text-sm text-kaspa-text outline-none focus:border-kaspa-primary" />
    </label>
  );
}

function AllocationPie({ rows }: { rows: HoldingRow[] }) {
  const slices = rows.filter((row) => (row.valueUsd || row.valueKas || 0) > 0).sort((a, b) => (b.valueUsd || b.valueKas || 0) - (a.valueUsd || a.valueKas || 0)).slice(0, 8);
  const total = slices.reduce((sum, row) => sum + (row.valueUsd || row.valueKas || 0), 0);
  const colors = ["#63e0ca", "#38bdf8", "#a78bfa", "#facc15", "#fb7185", "#34d399", "#f97316", "#c084fc"];
  let offset = 0;
  const gradient = slices.map((row, index) => {
    const share = total > 0 ? (row.valueUsd || row.valueKas || 0) / total * 100 : 0;
    const start = offset;
    offset += share;
    return `${colors[index % colors.length]} ${start}% ${offset}%`;
  }).join(", ");

  return (
    <div className="kaspa-panel rounded-md p-5">
      <div className="mb-4 flex items-center gap-2">
        <PieChart className="h-5 w-5 text-kaspa-primary" aria-hidden="true" />
        <h2 className="text-lg font-bold text-kaspa-text">Allocation</h2>
      </div>
      {slices.length === 0 ? (
        <div className="flex h-72 items-center justify-center rounded-md border border-kaspa-border bg-kaspa-background text-sm text-kaspa-muted">No holdings yet</div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-[180px_1fr] xl:grid-cols-1 2xl:grid-cols-[180px_1fr]">
          <div className="mx-auto h-44 w-44 rounded-full border border-kaspa-border" style={{ background: `conic-gradient(${gradient})` }} />
          <div className="space-y-2">
            {slices.map((row, index) => (
              <div key={row.token.id} className="flex items-center justify-between gap-3 rounded-md border border-kaspa-border bg-kaspa-background px-3 py-2">
                <div className="flex min-w-0 items-center gap-2">
                  <span className="h-3 w-3 shrink-0 rounded-full" style={{ backgroundColor: colors[index % colors.length] }} />
                  <span className="truncate font-bold text-kaspa-text">{row.token.symbol}</span>
                </div>
                <span className="text-sm text-kaspa-muted">{formatTokenAmount(row.portfolioShare)}%</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function MovementPanel({ movers }: { movers: ReturnType<typeof buildMovers> }) {
  return (
    <div className="kaspa-panel mb-6 rounded-md p-5">
      <h2 className="mb-4 text-lg font-bold text-kaspa-text">What moved my portfolio today?</h2>
      {movers.length === 0 ? (
        <div className="rounded-md border border-kaspa-border bg-kaspa-background px-4 py-3 text-sm text-kaspa-muted">Add balances to see the strongest 24h portfolio movers.</div>
      ) : (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-5">
          {movers.map(({ row, change, impactUsd, impactKas }) => (
            <div key={row.token.id} className="rounded-md border border-kaspa-border bg-kaspa-background p-3">
              <div className="mb-3 flex items-start justify-between gap-3">
                <div className="flex min-w-0 items-center gap-2">
                  <TokenLogo src={row.token.image_url} symbol={row.token.symbol} size="sm" />
                  <div className="min-w-0"><div className="whitespace-nowrap font-bold leading-tight text-kaspa-text">{row.token.symbol}</div><div className={["text-xs", change !== null && change >= 0 ? "text-kaspa-primary" : "text-red-300"].join(" ")}><DirectionalPercent value={change} /></div></div>
                </div>
                <div className="shrink-0 text-right">
                  <div className="text-[10px] font-bold text-kaspa-muted">Holdings</div>
                  <div className="text-[11px] font-bold text-kaspa-text">{formatTokenAmount(row.balance)}</div>
                  <div className="text-[10px] text-kaspa-muted">{formatKas(row.valueKas)} / {formatCurrency(row.valueUsd)}</div>
                </div>
              </div>
              <div className={["text-lg font-bold", (impactUsd ?? impactKas ?? 0) >= 0 ? "text-kaspa-primary" : "text-red-300"].join(" ")}>
                {impactUsd !== null ? formatSignedCurrency(impactUsd) : formatSignedKas(impactKas)}
              </div>
              <div className="text-xs text-kaspa-muted">estimated 24h impact</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function PortfolioChart({ points }: { points: PortfolioPoint[] }) {
  const usable = points.filter((point) => point.value_usd !== null || point.value_kas !== null);
  if (usable.length < 2) {
    return (
      <div className="flex h-72 items-center justify-center rounded-md border border-kaspa-border bg-kaspa-background text-sm text-kaspa-muted">
        Not enough portfolio history yet
      </div>
    );
  }
  const width = 900;
  const height = 280;
  const padding = { top: 18, right: 18, bottom: 28, left: 58 };
  const values = usable.map((point) => point.value_usd ?? point.value_kas ?? 0);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const start = usable[0].time;
  const end = usable[usable.length - 1].time;
  const span = Math.max(1, end - start);
  const range = Math.max(1, max - min);
  const x = (time: number) => padding.left + (time - start) / span * (width - padding.left - padding.right);
  const y = (value: number) => height - padding.bottom - (value - min) / range * (height - padding.top - padding.bottom);
  const path = usable.map((point, index) => `${index === 0 ? "M" : "L"} ${x(point.time)} ${y(point.value_usd ?? point.value_kas ?? 0)}`).join(" ");
  const change = values[0] > 0 ? (values[values.length - 1] - values[0]) / values[0] * 100 : null;

  return (
    <div>
      <div className="mb-3 flex items-center justify-between text-sm">
        <span className="text-kaspa-muted">{usable.length} points</span>
        <span className={["font-bold", change !== null && change >= 0 ? "text-kaspa-primary" : "text-red-300"].join(" ")}><DirectionalPercent value={change} /></span>
      </div>
      <svg className="h-72 w-full overflow-visible" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Portfolio value chart">
        <defs>
          <linearGradient id="portfolio-fill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.24" />
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
          </linearGradient>
        </defs>
        <path d={`${path} L ${x(usable[usable.length - 1].time)} ${height - padding.bottom} L ${x(usable[0].time)} ${height - padding.bottom} Z`} fill="url(#portfolio-fill)" />
        <path d={path} fill="none" stroke="var(--accent)" strokeLinecap="round" strokeLinejoin="round" strokeWidth="3" />
      </svg>
    </div>
  );
}

function parseNumber(value: string | number | null | undefined) {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (!value) return 0;
  const parsed = Number(String(value).trim().replace(",", "."));
  return Number.isFinite(parsed) ? parsed : 0;
}

function parseOptionalNumber(value: string | number | null | undefined) {
  if (typeof value === "number") return Number.isFinite(value) && value > 0 ? value : null;
  if (!value || !String(value).trim()) return null;
  const parsed = Number(String(value).trim().replace(",", "."));
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function displayEditableNumber(value: string | number | null | undefined) {
  const parsed = parseOptionalNumber(value);
  return parsed === null ? "" : formatPlainDecimal(value);
}

function formatInputBalance(value: number, useGrouping = false) {
  if (!Number.isFinite(value)) return "";
  if (!useGrouping) return formatPlainDecimal(value);
  return new Intl.NumberFormat("en-US", {
    useGrouping,
    maximumSignificantDigits: 15,
    maximumFractionDigits: 20
  }).format(value);
}

function toDateTimeInputValue(date: Date) {
  const offset = date.getTimezoneOffset();
  const local = new Date(date.getTime() - offset * 60 * 1000);
  return local.toISOString().slice(0, 19);
}

function buildTransactionsCsv(transactions: PortfolioTransaction[], tokenById: Map<string, Token>) {
  const headers = ["date", "token_id", "symbol", "name", "type", "amount", "price_kas", "price_usd", "fee_kas", "fee_usd", "total_kas", "total_usd", "note"];
  const rows = transactions.map((transaction) => {
    const token = tokenById.get(transaction.token_id);
    const amount = parseNumber(transaction.amount);
    const totalKas = amount * parseNumber(transaction.price_kas) + parseNumber(transaction.fee_kas);
    const totalUsd = amount * parseNumber(transaction.price_usd) + parseNumber(transaction.fee_usd);
    return [
      transaction.timestamp,
      transaction.token_id,
      token?.symbol || "",
      token?.name || "",
      transaction.type,
      formatPlainDecimal(transaction.amount),
      formatPlainDecimal(transaction.price_kas),
      formatPlainDecimal(transaction.price_usd),
      formatPlainDecimal(transaction.fee_kas),
      formatPlainDecimal(transaction.fee_usd),
      formatPlainDecimal(totalKas),
      formatPlainDecimal(totalUsd),
      transaction.note || ""
    ];
  });
  return [headers, ...rows].map((row) => row.map(csvCell).join(",")).join("\n");
}

function parseTransactionsCsv(raw: string, tokenById: Map<string, Token>, tokenBySymbol: Map<string, Token>): Array<Omit<PortfolioTransaction, "id">> {
  const rows = parseCsvRows(raw).filter((row) => row.some((cell) => cell.trim()));
  if (rows.length < 2) {
    throw new Error("CSV contains no transaction rows.");
  }

  const headers = rows[0].map((header) => normalizeCsvHeader(header));
  const transactions: Array<Omit<PortfolioTransaction, "id">> = [];

  for (const row of rows.slice(1)) {
    const value = (name: string) => {
      const index = headers.indexOf(name);
      return index >= 0 ? (row[index] || "").trim() : "";
    };
    const type = value("type").toLowerCase();
    const tokenIdFromCsv = value("token_id");
    const symbol = value("symbol").toUpperCase();
    const tokenId = tokenById.has(tokenIdFromCsv)
      ? tokenIdFromCsv
      : tokenBySymbol.get(symbol)?.id || tokenIdFromCsv;
    const amount = value("amount");
    const timestampValue = value("timestamp") || value("date");
    const timestamp = normalizeCsvTimestamp(timestampValue);

    if (!tokenId || (type !== "buy" && type !== "sell") || parseNumber(amount) <= 0 || !timestamp) {
      continue;
    }

    transactions.push({
      token_id: tokenId,
      type,
      amount,
      price_kas: value("price_kas"),
      price_usd: value("price_usd"),
      fee_kas: value("fee_kas"),
      fee_usd: value("fee_usd"),
      timestamp,
      note: value("note")
    });
  }

  if (transactions.length === 0) {
    throw new Error("No valid transactions found. Required columns: token_id or symbol, type, amount, date.");
  }

  return transactions;
}

function parseCsvRows(raw: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;

  for (let index = 0; index < raw.length; index += 1) {
    const char = raw[index];
    const next = raw[index + 1];
    if (quoted) {
      if (char === '"' && next === '"') {
        cell += '"';
        index += 1;
      } else if (char === '"') {
        quoted = false;
      } else {
        cell += char;
      }
      continue;
    }
    if (char === '"') {
      quoted = true;
    } else if (char === ",") {
      row.push(cell);
      cell = "";
    } else if (char === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else if (char !== "\r") {
      cell += char;
    }
  }

  row.push(cell);
  rows.push(row);
  return rows;
}

function normalizeCsvHeader(value: string) {
  return value.trim().toLowerCase().replace(/\s+/g, "_");
}

function normalizeCsvTimestamp(value: string) {
  if (!value) return "";
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : "";
}

function csvCell(value: string) {
  const escaped = value.replace(/"/g, '""');
  return /[",\n\r]/.test(escaped) ? `"${escaped}"` : escaped;
}

