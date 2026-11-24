import { useCallback, useEffect, useMemo, useState } from "react";
import { formatPlainDecimal } from "../utils/format";

const storageKey = "kaspa-token-explorer-portfolio-v1";
const eventName = "kaspa-portfolio-updated";

export interface PortfolioState {
  version: 1;
  favorites: string[];
  balances: Record<string, string>;
  transactions: PortfolioTransaction[];
  snapshots: PortfolioSnapshot[];
  createdAt: string;
  updatedAt: string;
}

export interface PortfolioTransaction {
  id: string;
  token_id: string;
  type: "buy" | "sell";
  amount: string;
  price_kas: string;
  price_usd: string;
  fee_kas?: string;
  fee_usd?: string;
  timestamp: string;
  note?: string;
}

export interface PortfolioSnapshot {
  timestamp: string;
  value_kas: number | null;
  value_usd: number | null;
}

function emptyState(): PortfolioState {
  const now = new Date().toISOString();
  return { version: 1, favorites: [], balances: {}, transactions: [], snapshots: [], createdAt: now, updatedAt: now };
}

function readState(): PortfolioState {
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return emptyState();
    const parsed = JSON.parse(raw) as Partial<PortfolioState>;
    return {
      version: 1,
      favorites: Array.isArray(parsed.favorites) ? [...new Set(parsed.favorites.filter((id): id is string => typeof id === "string"))] : [],
      balances: parsed.balances && typeof parsed.balances === "object" ? normalizeBalances(parsed.balances) : {},
      transactions: Array.isArray(parsed.transactions) ? parsed.transactions.filter(isTransaction).slice(-10000) : [],
      snapshots: Array.isArray(parsed.snapshots) ? parsed.snapshots.filter(isSnapshot).slice(-1000) : [],
      createdAt: typeof parsed.createdAt === "string" ? parsed.createdAt : new Date().toISOString(),
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : new Date().toISOString()
    };
  } catch {
    return emptyState();
  }
}

function isSnapshot(value: unknown): value is PortfolioSnapshot {
  if (!value || typeof value !== "object") return false;
  const item = value as Partial<PortfolioSnapshot>;
  return typeof item.timestamp === "string";
}

function isTransaction(value: unknown): value is PortfolioTransaction {
  if (!value || typeof value !== "object") return false;
  const item = value as Partial<PortfolioTransaction>;
  return (
    typeof item.id === "string" &&
    typeof item.token_id === "string" &&
    (item.type === "buy" || item.type === "sell") &&
    typeof item.amount === "string" &&
    typeof item.price_kas === "string" &&
    typeof item.price_usd === "string" &&
    typeof item.timestamp === "string"
  );
}

function normalizeBalances(source: Record<string, unknown>) {
  const balances: Record<string, string> = {};
  for (const [id, value] of Object.entries(source)) {
    if (typeof value === "string" || typeof value === "number") {
      const parsed = parseBalance(String(value));
      balances[id] = parsed > 0 ? formatStoredBalance(parsed) : "";
    }
  }
  return balances;
}

function writeState(next: PortfolioState) {
  window.localStorage.setItem(storageKey, JSON.stringify(next));
  window.dispatchEvent(new CustomEvent<PortfolioState>(eventName, { detail: next }));
}

function parseBalance(value: string | undefined) {
  if (!value) return 0;
  const normalized = normalizeNumberInput(value);
  const parsed = Number(normalized);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function formatStoredBalance(value: number) {
  if (!Number.isFinite(value) || value <= 0) {
    return "";
  }
  return formatPlainDecimal(value);
}

function normalizeNumberInput(value: string) {
  const trimmed = value.trim().replace(/\s/g, "");
  if (trimmed.includes(",") && trimmed.includes(".")) {
    return trimmed.replace(/,/g, "");
  }
  if ((trimmed.match(/,/g) || []).length > 1 || /^\d{1,3}(,\d{3})+(\.\d+)?$/.test(trimmed) || /^\d{1,3}(,\d{3,})$/.test(trimmed)) {
    return trimmed.replace(/,/g, "");
  }
  return trimmed.replace(",", ".");
}

export function usePortfolioStore() {
  const [state, setState] = useState<PortfolioState>(() => readState());

  useEffect(() => {
    function sync(event: Event) {
      if (event instanceof CustomEvent && event.detail) {
        setState(event.detail as PortfolioState);
        return;
      }
      setState(readState());
    }
    window.addEventListener("storage", sync);
    window.addEventListener(eventName, sync);
    return () => {
      window.removeEventListener("storage", sync);
      window.removeEventListener(eventName, sync);
    };
  }, []);

  const save = useCallback((updater: (current: PortfolioState) => PortfolioState) => {
    const current = readState();
    const next = updater(current);
    const normalized = { ...next, favorites: [...new Set(next.favorites)], updatedAt: new Date().toISOString() };
    writeState(normalized);
    setState(normalized);
  }, []);

  const favoriteIds = useMemo(() => new Set(state.favorites), [state.favorites]);

  const isFavorite = useCallback((tokenId: string) => favoriteIds.has(tokenId), [favoriteIds]);

  const toggleFavorite = useCallback((tokenId: string) => {
    save((current) => {
      const favorites = new Set(current.favorites);
      if (favorites.has(tokenId)) {
        favorites.delete(tokenId);
      } else {
        favorites.add(tokenId);
      }
      return { ...current, favorites: [...favorites] };
    });
  }, [save]);

  const setBalance = useCallback((tokenId: string, value: string) => {
    save((current) => {
      const balances = { ...current.balances, [tokenId]: value };
      return { ...current, balances };
    });
  }, [save]);

  const addBalance = useCallback((tokenId: string, value: string) => {
    save((current) => {
      const currentBalance = parseBalance(current.balances[tokenId]);
      const incomingBalance = parseBalance(value);
      if (incomingBalance <= 0) return current;
      const balances = { ...current.balances, [tokenId]: formatStoredBalance(currentBalance + incomingBalance) };
      return { ...current, balances };
    });
  }, [save]);

  const removeToken = useCallback((tokenId: string) => {
    save((current) => {
      const balances = { ...current.balances };
      const transactions = current.transactions.filter((transaction) => transaction.token_id !== tokenId);
      delete balances[tokenId];
      return { ...current, balances, transactions };
    });
  }, [save]);

  const addTransaction = useCallback((transaction: Omit<PortfolioTransaction, "id">) => {
    save((current) => {
      return {
        ...current,
        transactions: [
          {
            ...transaction,
            id: typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : String(Date.now())
          },
          ...current.transactions
        ].slice(0, 10000)
      };
    });
  }, [save]);

  const updateTransaction = useCallback((transactionId: string, updates: Omit<PortfolioTransaction, "id">) => {
    save((current) => {
      return {
        ...current,
        transactions: current.transactions.map((transaction) => transaction.id === transactionId ? { ...updates, id: transaction.id } : transaction)
      };
    });
  }, [save]);

  const importTransactions = useCallback((transactions: Array<Omit<PortfolioTransaction, "id">>) => {
    let imported = 0;
    save((current) => {
      const seen = new Set(current.transactions.map(transactionSignature));
      const nextTransactions: PortfolioTransaction[] = [];

      for (const transaction of transactions) {
        const signature = transactionSignature(transaction);
        if (seen.has(signature)) {
          continue;
        }
        seen.add(signature);
        nextTransactions.push({
          ...transaction,
          id: typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${imported}`
        });
        imported += 1;
      }

      if (nextTransactions.length === 0) {
        return current;
      }

      return {
        ...current,
        transactions: [...nextTransactions, ...current.transactions].slice(0, 10000)
      };
    });
    return imported;
  }, [save]);

  const removeTransaction = useCallback((transactionId: string) => {
    save((current) => ({
      ...current,
      transactions: current.transactions.filter((transaction) => transaction.id !== transactionId)
    }));
  }, [save]);

  const recordSnapshot = useCallback((valueKas: number | null, valueUsd: number | null) => {
    save((current) => {
      if (valueKas === null && valueUsd === null) return current;
      const now = new Date();
      const today = now.toISOString().slice(0, 10);
      const snapshots = current.snapshots.filter((snapshot) => snapshot.timestamp.slice(0, 10) !== today);
      snapshots.push({ timestamp: now.toISOString(), value_kas: valueKas, value_usd: valueUsd });
      return { ...current, snapshots: snapshots.slice(-1000) };
    });
  }, [save]);

  const importPortfolio = useCallback((raw: string) => {
    const parsed = JSON.parse(raw) as Partial<PortfolioState>;
    const current = readState();
    const now = new Date().toISOString();
    const next: PortfolioState = {
      version: 1,
      favorites: current.favorites,
      balances: parsed.balances && typeof parsed.balances === "object" ? normalizeBalances(parsed.balances) : {},
      transactions: Array.isArray(parsed.transactions) ? parsed.transactions.filter(isTransaction).slice(-10000) : [],
      snapshots: Array.isArray(parsed.snapshots) ? parsed.snapshots.filter(isSnapshot).slice(-1000) : [],
      createdAt: typeof parsed.createdAt === "string" ? parsed.createdAt : now,
      updatedAt: now
    };
    writeState(next);
    setState(next);
  }, []);

  const exportPortfolio = useCallback(() => {
    const { favorites: _favorites, ...portfolioOnly } = state;
    return JSON.stringify(portfolioOnly, null, 2);
  }, [state]);

  return { state, favoriteIds, isFavorite, toggleFavorite, setBalance, addBalance, removeToken, addTransaction, updateTransaction, importTransactions, removeTransaction, recordSnapshot, importPortfolio, exportPortfolio };
}

export function numericBalance(value: string | undefined) {
  return parseBalance(value);
}

function transactionSignature(transaction: Omit<PortfolioTransaction, "id"> | PortfolioTransaction) {
  return [
    transaction.token_id,
    transaction.type,
    transaction.amount,
    transaction.price_kas,
    transaction.price_usd,
    transaction.fee_kas || "",
    transaction.fee_usd || "",
    transaction.timestamp,
    transaction.note || ""
  ].join("|");
}

