export type TokenLayer = "KRC20" | "KCC20" | "KRC721" | "L2";
export type TokenSourceStatus = "LIVE" | "PARTIAL" | "TO_CONFIRM" | "DISABLED";
export type TransactionType = "buy" | "list" | "mint" | "transfer";
export type ChartRange = "24h" | "7d" | "30d" | "1y" | "all";

export interface VolumeHistoryCoverage {
  status: "complete" | "partial" | "unavailable";
  from: number | null;
  to: number;
  covered_hours: number;
  expected_hours: number;
  missing_hours: number;
  missing_fx_hours: number;
}

export interface TokenMarket {
  id: string;
  name: string;
  type: "L1_MARKETPLACE" | "DEX";
  price_kas: number | null;
  price_usd: number | null;
  volume_24h_usd?: number;
  volume_7d_usd?: number;
  volume_30d_usd?: number;
  volume_7d_available?: boolean;
  volume_30d_available?: boolean;
  volume_7d_history?: VolumeHistoryCoverage;
  volume_30d_history?: VolumeHistoryCoverage;
  dex_liquidity?: number | null;
  source_status: TokenSourceStatus;
  network?: string;
  contract_address?: string;
  notes?: string;
}

export interface TokenSocialLinks {
  website?: string;
  twitter?: string;
  telegram?: string;
  discord?: string;
}

export interface Token {
  id: string;
  symbol: string;
  name: string;
  layer: TokenLayer;
  price_kas: number | null;
  price_usd: number | null;
  market_cap_kas: number | null;
  market_cap_usd: number | null;
  unusual_market_cap?: boolean;
  volume_24h_usd: number;
  volume_7d_usd: number;
  volume_30d_usd: number;
  volume_24h_kas?: number | null;
  volume_7d_kas?: number | null;
  volume_30d_kas?: number | null;
  all_time_volume_kas?: number | null;
  all_time_volume_usd?: number | null;
  volume_7d_available?: boolean;
  volume_30d_available?: boolean;
  volume_7d_history?: VolumeHistoryCoverage;
  volume_30d_history?: VolumeHistoryCoverage;
  price_change_24h_percent: number | null;
  price_change_7d_percent: number | null;
  holders: number | null;
  transfers: number | null;
  premint_percent?: number | null;
  mint_percent?: number | null;
  mint_activity_count?: number | null;
  mint_activity_window?: string | null;
  total_supply?: number | null;
  total_minted?: number | null;
  burned_supply?: number | null;
  mint_price_kas?: number | null;
  deployed_at?: string | null;
  image_url?: string;
  verified: boolean;
  verification_reason: string;
  contract_address?: string;
  dex_liquidity?: number | null;
  source_status: TokenSourceStatus;
  source?: string;
  markets?: TokenMarket[];
  description?: string;
  banner_url?: string;
  browse_url?: string;
  socials?: TokenSocialLinks;
}

export interface Holder {
  address: string;
  percentage: number;
  balance: number;
  last_tx_at?: string | null;
  last_wallet_tx_at?: string | null;
}

export interface HolderActivity {
  address: string;
  last_tx_at?: string | null;
  last_wallet_tx_at?: string | null;
}

export interface Krc721HolderSnapshotRow {
  address: string;
  balance: number;
  token_ids: string[];
}

export interface Krc721HolderSnapshot {
  ticker: string;
  generated_at: string;
  total_holders: number;
  total_tokens: number;
  holders: Krc721HolderSnapshotRow[];
  text: string;
}

export interface TokenTransaction {
  id: string;
  type: TransactionType;
  token_id: string;
  token_symbol?: string;
  amount: number;
  price_kas: number | null;
  price_usd: number | null;
  wallet: string;
  from_wallet?: string;
  to_wallet?: string;
  timestamp: string;
  tx_url?: string;
}

export type WalletNetwork = "krc20" | "kasplex" | "igra";

export interface WalletTokenBalance {
  token_id?: string;
  symbol: string;
  name?: string;
  balance: number | null;
  units_status?: 'verified'|'unavailable'|'conflict';
  contract_address?: string;
  image_url?: string | null;
  decimals?:number;
  raw_balance?:string;
}

export interface Krc721WalletNft {
  ticker: string;
  token_id: string;
  image_url: string | null;
  rarity_rank: number | null;
  collection_token_id: string;
  collection_url: string;
  nexus_url: string;
}

export interface Krc721WalletCollection {
  address: string;
  ticker: string;
  collection_token_id: string;
  collection_url: string;
  nexus_url: string;
  total: number;
  next_offset: number | null;
  nfts: Krc721WalletNft[];
}

export interface WalletDomain {
  name: string;
  status?: string;
}

export interface WalletDetail {
  kcc20_index_status?:Kcc20WalletStatus|null;
  krc20_status?:"ready"|"partial"|"unavailable";
  kns_status?:"ready"|"partial"|"unavailable";
  network: WalletNetwork;
  address: string;
  native_symbol: "KAS" | "WKAS" | "iKAS";
  native_balance: number | null;
  domains: WalletDomain[];
  tokens: WalletTokenBalance[];
  krc721_tokens?: WalletTokenBalance[];
  krc721_status?: "ready" | "unavailable" | "deferred";
  transactions: TokenTransaction[];
}

export interface Kcc20WalletStatus {
  indexed_tokens?:number;
  pending_transactions?:number;
  updated_at?:number|null;
  expected_tokens?:number;
  balance_state?:"ready"|"partial"|"unavailable";
  balance_source?:string;
  balance_warnings?:string[];
  balances_complete?:boolean;
}

export interface Kcc20WalletHoldings {address:string;tokens:WalletTokenBalance[];status:Kcc20WalletStatus|null}

export interface ChartPoint {
  time: number;
  price_kas: number | null;
  price_usd: number | null;
  change_percent?: number | null;
}

export interface SourceNotice {
  id: string;
  name: string;
  status: TokenSourceStatus | "CONFIRMED" | "CONFIG_REQUIRED";
  base_url?: string;
  notes: string[];
}

export interface ApiEnvelope<T> {
  data: T;
  updated_at: string;
  source_mode: TokenSourceStatus;
  warnings?: string[];
}

export interface TokenListResponse {
  tokens: Token[];
}

export interface MarketOverview {
  tokens_total: number;
  verified_tokens: number;
  volume_24h_usd: number;
  volume_7d_usd: number;
  volume_30d_usd: number;
  market_cap_usd: number;
  layers: Record<TokenLayer, number>;
}

export interface HomeSummary {
  kcc20: {
    volume_24h_usd: number;
    volume_24h_kas: number;
    gainers: HomeSummaryToken[];
    losers: HomeSummaryToken[];
  };
  krc20: {
    volume_24h_usd: number;
    gainers: HomeSummaryToken[];
    losers: HomeSummaryToken[];
  };
  krc721: {
    volume_24h_kas: number;
    top_volume: HomeSummaryToken[];
  };
  l2: {
    volume_24h_usd: number;
    gainers: HomeSummaryToken[];
    losers: HomeSummaryToken[];
  };
}

export interface HomeSummaryToken {
  id: string;
  symbol: string;
  name: string;
  layer: TokenLayer;
  image_url?: string;
  volume_24h_usd?: number;
  volume_24h_kas?: number | null;
  price_change_24h_percent?: number | null;
}

export interface HomeSearchIndex {
  tokens: HomeSummaryToken[];
}

export interface KaspaStatsPoint {
  time: number;
  price_usd: number | null;
}

export interface KaspaHashratePoint {
  time: number;
  hashrate_kh: number | null;
}

export type KaspaStatsRange = "24h" | "3d" | "7d";

export type Kcc20ValidationStatus = "verified" | "template_verified" | "invalid" | "unvalidated";

export interface Kcc20Token {
  covenant_id: string;
  name: string;
  claimed_name: string | null;
  claimed_ticker: string | null;
  image_url: string | null;
  claimed_image_url: string | null;
  claimed_image_hash: string | null;
  metadata_source: string | null;
  template: string;
  standard: string | null;
  decimals: number;
  action_count: number;
  genesis_daa: number | null;
  ranking_tier: string | null;
  organic_rank: number | null;
  status: Kcc20ValidationStatus;
  alive: boolean;
  supply: number;
  minted: number;
  burned: number;
  holders: number;
  last_activity_daa: number | null;
  live_value_sompi: number | null;
  unresolved_cells: number;
  invalid_reason: string | null;
  fields: Record<string, string>;
}

export interface Kcc20TokenList {
  network: "mainnet";
  note: string;
  tip_daa: number | null;
  tip_at_ms: number | null;
  generated_at_ms: number | null;
  tokens: Kcc20Token[];
}

export interface Kcc20Balance {
  owner: string;
  owner_address: string | null;
  balance: number;
  cells: number | null;
}

export interface Kcc20Event {
  txid: string;
  accepting_daa: number;
  accepted_at_ms: number | null;
  tx_index: number | null;
  seq: number;
  delta_idx: number | null;
  event_kind: string;
  token_kind: string;
  amount: number | null;
  owner_from: string | null;
  owner_from_address: string | null;
  owner_to: string | null;
  owner_to_address: string | null;
}

export interface Kcc20OwnerChange {
  direction: "from" | "to";
  owner: string;
  owner_address: string | null;
  amount: number;
}

export interface Kcc20TransactionOwners {
  txid: string;
  owner_changes: Kcc20OwnerChange[];
}

export interface Kcc20TokenDetail extends Kcc20TokenList {
  token: Kcc20Token;
  balances: Kcc20Balance[];
  events: Kcc20Event[];
  validation: {
    status: Kcc20ValidationStatus;
    checked: number;
    unresolved_cells: number;
    reason: string | null;
    derivation_version: string | null;
    derived_at_daa: number | null;
  };
}

export type Kcc20DexInterval = "1m" | "5m" | "1h" | "1d";

export interface Kcc20DexMarket {
  source_status?: TokenSourceStatus;
  liquidity_label?: string;
  venue?: string;
  trade_url?: string;
  supply?: number;
  burned?: number;
  validation_status?: Kcc20ValidationStatus;
  ticker: string;
  name: string;
  image_url?: string | null;
  decimals: number;
  graduated: boolean;
  covenant_id: string;
  holders: number;
  minted: number;
  price_kas: number | null;
  price_usd?: number | null;
  change_24h_percent: number | null;
  volume_24h_kas: number;
  volume_total_kas: number;
  tvl_kas: number;
  trades_24h: number;
  trades_total: number;
  market_cap_kas: number | null;
  market_cap_usd?: number | null;
  volume_24h_usd?: number;
  tvl_usd?: number | null;
  token_reserve: number;
  reserve_kas: number;
  sparkline: number[];
}

export interface Kcc20DexCandle {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume_kas: number;
}

export interface Kcc20DexTrade {
  txid: string;
  time: number;
  side: "buy" | "sell" | string;
  kind: string;
  price_kas: number;
  volume_kas: number;
}

export interface Kcc20DexTokenDetail {
  market: Kcc20DexMarket | null;
  interval: Kcc20DexInterval;
  candles: Kcc20DexCandle[];
  trades: Kcc20DexTrade[];
}

export interface KaspaStats {
  price_usd: number | null;
  market_cap_usd: number | null;
  latest_hashrate_kh: number | null;
  latest_hashrate_at: string | null;
  range: KaspaStatsRange;
  chart: KaspaStatsPoint[];
  price_chart: KaspaStatsPoint[];
  hashrate_chart: KaspaHashratePoint[];
}

export interface KnsDomain {
  name: string;
  asset_id: string | null;
  owner: string | null;
  created_at: string | null;
  verified: boolean;
  status: string | null;
  transaction_id: string | null;
}

export interface KnsSale {
  domain: string;
  asset_id: string | null;
  seller: string | null;
  buyer: string | null;
  price_kas: number | null;
  timestamp: string | null;
}

export interface KnsTradeStat {
  domain: string;
  total_trades: number;
  total_volume_kas: number;
}

export interface KnsGraphPoint {
  date: string;
  time: number;
  total_trades: number;
  total_volume_kas: number;
  avg_sale_price_kas: number | null;
}

export interface KnsMarketplace {
  query: string;
  domains_total: number | null;
  domains: KnsDomain[];
  recent_sales: KnsSale[];
  top_domains: KnsTradeStat[];
  graph: KnsGraphPoint[];
  totals: {
    volume_kas: number;
    trades: number;
    avg_sale_price_kas: number | null;
  };
}

