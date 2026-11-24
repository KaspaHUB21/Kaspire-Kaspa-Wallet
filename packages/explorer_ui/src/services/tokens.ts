import { useEffect, useMemo, useState } from "react";
import { getChart, getHolders, getHomeSearchIndex, getHomeSummary, getKaspaStats, getKcc20DexMarkets, getKcc20DexToken, getKcc20Token, getKcc20Tokens, getKcc20TransactionOwners, getKnsMarketplace, getKnsSearch, getSources, getToken, getTokens, getWallet, getWalletKrc721Collection, getWalletKrc721Holdings } from "./api";
import type { ApiEnvelope, ChartPoint, ChartRange, Holder, HomeSearchIndex, HomeSummary, KaspaStats, KaspaStatsRange, Kcc20DexInterval, Kcc20DexMarket, Kcc20DexTokenDetail, Kcc20TokenDetail, Kcc20TokenList, Kcc20TransactionOwners, KnsMarketplace, Krc721WalletCollection, MarketOverview, SourceNotice, Token, TokenLayer, TokenTransaction, TransactionType, WalletDetail, WalletNetwork } from "../types/token";

interface AsyncState<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
  envelope: ApiEnvelope<T> | null;
}

function useAsync<T>(loader: () => Promise<ApiEnvelope<T>>, deps: unknown[], refreshMs = 0): AsyncState<T> {
  const [state, setState] = useState<AsyncState<T>>({ data: null, loading: true, error: null, envelope: null });

  useEffect(() => {
    let active = true;
    const load = (initial = false) => {
      if (initial) {
        setState((current) => ({ ...current, loading: true, error: null }));
      }
      loader()
      .then((envelope) => {
        if (active) {
          setState({ data: envelope.data, loading: false, error: null, envelope });
        }
      })
      .catch((error: Error) => {
        if (active) {
          setState((current) => initial
            ? { data: null, loading: false, error: error.message, envelope: null }
            : { ...current, loading: false, error: error.message });
        }
      });
    };

    load(true);
    const timer = refreshMs > 0 ? window.setInterval(() => load(false), refreshMs) : null;
    const refreshWhenVisible = () => {
      if (refreshMs > 0 && document.visibilityState === "visible") {
        load(false);
      }
    };
    document.addEventListener("visibilitychange", refreshWhenVisible);

    return () => {
      active = false;
      if (timer !== null) {
        window.clearInterval(timer);
      }
      document.removeEventListener("visibilitychange", refreshWhenVisible);
    };
  }, [...deps, refreshMs]);

  return state;
}

export function useTokens(layer: TokenLayer) {
  return useAsync(() => getTokens(layer), [layer], 5 * 60 * 1000);
}

export function useKcc20Tokens() {
  return useAsync<Kcc20TokenList>(() => getKcc20Tokens(), []);
}

export function useKcc20Token(covenantId: string | undefined) {
  return useAsync<Kcc20TokenDetail>(() => getKcc20Token(covenantId || ""), [covenantId]);
}

export function useKcc20TransactionOwners(covenantId: string | undefined, txids: string[], enabled: boolean) {
  const txidKey = txids.join(",");
  return useAsync<{ transactions: Kcc20TransactionOwners[] }>(() => enabled && covenantId && txids.length
    ? getKcc20TransactionOwners(covenantId, txids)
    : Promise.resolve({ data: { transactions: [] }, updated_at: new Date().toISOString(), source_mode: "DISABLED" as const }),
  [covenantId, txidKey, enabled]);
}

export function useKcc20DexMarkets() {
  return useAsync<{ markets: Kcc20DexMarket[] }>(() => getKcc20DexMarkets(), []);
}

export function useKcc20DexToken(covenantId: string | undefined, interval: Kcc20DexInterval) {
  return useAsync<Kcc20DexTokenDetail>(
    () => covenantId ? getKcc20DexToken(covenantId, interval) : Promise.resolve({
      data: { market: null, interval, candles: [], trades: [] },
      updated_at: new Date().toISOString(),
      source_mode: "DISABLED" as const
    }),
    [covenantId, interval]
  );
}

export function useExplorerTokens(layer: TokenLayer | "COMBINED") {
  return useAsync(async () => {
    if (layer !== "COMBINED") {
      return getTokens(layer);
    }

    const [krc20, kcc20, l2] = await Promise.all([getTokens("KRC20"), getTokens("KCC20"), getTokens("L2")]);
    const tokens = [...krc20.data.tokens, ...kcc20.data.tokens, ...l2.data.tokens];
    return {
      data: { tokens },
      updated_at: new Date().toISOString(),
      source_mode: krc20.source_mode === "LIVE" && kcc20.source_mode === "LIVE" && l2.source_mode === "LIVE" ? "LIVE" as const : "PARTIAL" as const,
      warnings: [...(krc20.warnings || []), ...(kcc20.warnings || []), ...(l2.warnings || [])]
    };
  }, [layer], 5 * 60 * 1000);
}

export function useHomeSummary() {
  return useAsync(() => getHomeSummary(), [], 5 * 60 * 1000);
}

export function useHomeSearchIndex(enabled: boolean) {
  return useAsync(() => enabled ? getHomeSearchIndex() : Promise.resolve({
    data: { tokens: [] },
    updated_at: new Date().toISOString(),
    source_mode: "DISABLED" as const
  }), [enabled]);
}

export function useKnsSearch(query: string, enabled: boolean) {
  return useAsync(() => enabled ? getKnsSearch(query) : Promise.resolve({
    data: { query: "", domains: [] },
    updated_at: new Date().toISOString(),
    source_mode: "DISABLED" as const
  }), [query, enabled]);
}

export function useToken(id: string | undefined) {
  return useAsync(() => getToken(id || ""), [id]);
}

export function useTokenChart(id:string,range:ChartRange){
  return useAsync(()=>getChart(id,range),[id,range],5*60*1000);
}

export function useTokenCollections(id: string | undefined, range: ChartRange, enabled = true) {
  const holders = useAsync(() => enabled ? getHolders(id || "") : Promise.resolve({ data: { holders: [] }, updated_at: new Date().toISOString(), source_mode: "DISABLED" as const }), [id, enabled]);
  const chart = useAsync(() => enabled ? getChart(id || "", range) : Promise.resolve({ data: { points: [] }, updated_at: new Date().toISOString(), source_mode: "DISABLED" as const }), [id, range, enabled], enabled ? 5 * 60 * 1000 : 0);

  return useMemo(() => ({ holders, chart }), [holders, chart]);
}

export function useSources() {
  return useAsync(() => getSources(), []);
}

export function useKaspaStats(range: KaspaStatsRange = "24h") {
  return useAsync(() => getKaspaStats(range), [range]);
}

export function useKnsMarketplace(query: string) {
  return useAsync(() => getKnsMarketplace(query), [query]);
}

export function useWallet(network: WalletNetwork | undefined, address: string | undefined, includeNfts = true) {
  const key=[network,address,includeNfts].join("|");
  const [activeKey,setActiveKey]=useState(key);
  useEffect(()=>setActiveKey(key),[key]);
  const state=useAsync(() => getWallet(network || "krc20", address || "", includeNfts,network!=="krc20"), [network, address, includeNfts],60000);
  return activeKey===key&&!state.loading?state:{...state,data:null,error:null,loading:true};
}

export function useWalletKrc721Holdings(address: string | undefined, enabled: boolean) {
  type Holdings = {address: string; tokens: NonNullable<WalletDetail["krc721_tokens"]>};
  const key = enabled && address ? address : "";
  const [state, setState] = useState<AsyncState<Holdings> & {key: string}>(() => ({
    key, data: null, loading: Boolean(key), error: null, envelope: null
  }));
  useEffect(() => {
    let active = true;
    setState({key, data: null, loading: Boolean(key), error: null, envelope: null});
    if (!key) return () => { active = false; };
    const load = () => {
      getWalletKrc721Holdings(key).then(envelope => {
        if (active) setState({key, data: envelope.data, loading: false, error: null, envelope});
      }).catch((error: Error) => {
        if (active) setState(previous => ({...previous, loading: false, error: error.message}));
      });
    };
    load();
    const timer = window.setInterval(load, 60000);
    const visible = () => { if (document.visibilityState === "visible") load(); };
    document.addEventListener("visibilitychange", visible);
    return () => { active = false; window.clearInterval(timer); document.removeEventListener("visibilitychange", visible); };
  }, [key]);
  // A navigation must never briefly show the previous wallet's NFTs or errors.
  return state.key === key ? state : {key, data: null, loading: Boolean(key), error: null, envelope: null};
}

export function useWalletKrc721Collection(address: string | undefined, ticker: string | undefined) {
  return useAsync(() => getWalletKrc721Collection(address || "", ticker || ""), [address, ticker]);
}

export type { ChartPoint, Holder, HomeSearchIndex, HomeSummary, KaspaStats, KnsMarketplace, Krc721WalletCollection, MarketOverview, SourceNotice, Token, TokenTransaction, WalletDetail };

