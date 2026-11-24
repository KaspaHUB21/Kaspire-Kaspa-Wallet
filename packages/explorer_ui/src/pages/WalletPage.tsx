import {ChainBalance,ChainActivity} from '../chain';
import {HoldingsSection} from '../components/HoldingsSection';
import {krc20Logo,publicImage} from '../images';
import {TokenLogo} from '../components/TokenLogo';
import { Link, useParams } from "react-router-dom";
import { DotkWalletNames } from "./DotkPage";
import { AlertTriangle, ArrowLeft, List, Tag, Trash2, Users } from "../components/icons";
import { EmptyState } from "../components/EmptyState";
import { LoadingState } from "../components/LoadingState";
import { MetricTile } from "../components/MetricTile";
import { TxTable } from "../components/TxTable";
import { WalletNftHoldings } from "../components/WalletNftHoldings";
import { WalletKcc20Holdings,kcc20BalanceCount } from "../components/WalletKcc20Holdings";
import { useWalletKcc20Holdings } from "../services/kcc20Wallet";
import { getWalletTransactions } from "../services/api";
import { useWallet, useWalletKrc721Holdings } from "../services/tokens";
import { useWalletLabels, type ResolvedWalletLabel } from "../services/walletLabels";
import type { TokenTransaction, WalletNetwork } from "../types/token";
import { formatKas, formatTokenAmount } from "../utils/format";
import { useEffect, useState } from "react";

function validNetwork(value: string | undefined): WalletNetwork {
  return value === "kasplex" || value === "igra" || value === "krc20" ? value : "krc20";
}

export function WalletPage() {
  const {network,address}=useParams(),walletNetwork=validNetwork(network);
  const wallet=useWallet(walletNetwork,address,walletNetwork!=='krc20'),nftState=useWalletKrc721Holdings(address,walletNetwork==='krc20'),kcc20State=useWalletKcc20Holdings(address,walletNetwork==='krc20');
  const data=wallet.data,resolved=data?.address||kcc20State.data?.address||nftState.data?.address||address||'';
  const {labelDetailsFor,personalLabelFor,removeLabel,setLabel}=useWalletLabels();
  const [activityTab,setActivityTab]=useState('all'),[tokensExpanded,setTokensExpanded]=useState(false),[labelModalOpen,setLabelModalOpen]=useState(false),[labelDraft,setLabelDraft]=useState('');
  const krc721Tokens=nftState.data?.tokens??[],regularTokens=(data?.tokens??[]).filter(t=>!t.token_id?.startsWith('kcc20-')),visibleTokens=tokensExpanded?regularTokens:regularTokens.slice(0,8);
  const kcc20Props={tokens:kcc20State.data?.tokens??[],loading:kcc20State.loading,error:kcc20State.error,confirmed:!!kcc20State.data,status:kcc20State.data?.status??null};
  const count=wallet.loading?'Loading…':!data?'Unavailable':data.krc20_status==='unavailable'?'Unavailable':data.krc20_status==='partial'?'Incomplete':regularTokens.length;
  const walletLabel=labelDetailsFor(resolved),personalLabel=personalLabelFor(resolved);
  return <section>
    <Link to="/" className="block mb-4">← Back to Explore</Link>
    <div className="flex flex-wrap items-center gap-3"><h1>Wallet</h1>{walletLabel?<WalletLabelBadge label={walletLabel}/>:null}<button aria-label="Add label" onClick={()=>{setLabelDraft(personalLabel??'');setLabelModalOpen(true)}}><Tag className="h-4 w-4"/></button><Link to="/labels" aria-label="Saved labels"><List className="h-4 w-4"/></Link></div>
    <p className="break-all text-xs mt-3 mb-5">{resolved}</p>
    {walletNetwork==='krc20'&&resolved.startsWith('kaspa:')?<ChainBalance key={resolved} address={resolved}/>:data?<MetricTile label={data.native_symbol+' Balance'} value={formatKas(data.native_balance).replace(' KAS',' '+data.native_symbol)}/>:<p role="status">Resolving wallet…</p>}
    {wallet.error?<p role="alert" className="my-3 text-kaspa-muted">Wallet token metadata temporarily unavailable. Other sources load independently.</p>:null}
    {walletNetwork==='krc20'||walletNetwork==='igra'?<HoldingsSection title={walletNetwork==='igra'?'INS':'KNS'} count={wallet.loading?'Loading…':data?.kns_status==='unavailable'?'Unavailable':data?.domains.length}>
      {wallet.loading?<p>Loading names…</p>:!data||data.kns_status==='unavailable'?<p>Names temporarily unavailable; not a confirmed empty wallet.</p>:<><div className="flex flex-wrap gap-2">{data.domains.map(d=><span className="rounded-md border border-kaspa-border p-2" key={d.name}>{d.name}</span>)}</div>{data.kns_status==='partial'?<p>Names coverage is incomplete.</p>:!data.domains.length?<p>No names found.</p>:null}</>}
    </HoldingsSection>:null}
    {walletNetwork==='krc20'&&resolved.startsWith('kaspa:')?<HoldingsSection title="dotK"><DotkWalletNames key={resolved} address={resolved}/></HoldingsSection>:null}
    <HoldingsSection title={walletNetwork==='krc20'?'KRC20':walletNetwork==='igra'?'Igra tokens':'Kasplex tokens'} count={count}>
      {wallet.loading?<p>Loading token balances…</p>:!data||data.krc20_status==='unavailable'?<p>Token balances are unavailable; not a confirmed empty wallet.</p>:<>
      {data.krc20_status==='partial'?<p>Token balances are incomplete. Previously loaded holdings are retained.</p>:null}
      <div data-wallet-regular-tokens className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{visibleTokens.map(t=><Link key={t.token_id||t.contract_address||t.symbol} to={t.token_id?'/token/'+encodeURIComponent(t.token_id):'#'} className="rounded-md border border-kaspa-border p-3"><div className="flex gap-3 items-center"><TokenLogo src={walletNetwork==='krc20'?krc20Logo(t.symbol):publicImage(t.image_url)} fallbackSrcs={[publicImage(t.image_url)]} symbol={t.symbol}/><b>{t.symbol}</b></div>{t.name&&t.name!==t.symbol?<p>{t.name}</p>:null}<p className="mt-3 font-bold">{formatWalletTokenBalance(t.balance,walletNetwork)}</p></Link>)}</div>
      {!regularTokens.length&&data.krc20_status!=='partial'?<p>No token balances found.</p>:null}{regularTokens.length>8?<button className="mt-4" onClick={()=>setTokensExpanded(v=>!v)}>{tokensExpanded?'Show less':'Show all'}</button>:null}</>}
    </HoldingsSection>
    {walletNetwork==='krc20'?<><HoldingsSection title="KCC20" count={kcc20BalanceCount(kcc20Props)}><WalletKcc20Holdings {...kcc20Props}/></HoldingsSection><HoldingsSection title="KRC721" count={nftState.loading?'Loading…':nftState.error?'Unavailable':nftState.data?krc721Tokens.length:'Unavailable'}><WalletNftHoldings address={resolved} tokens={krc721Tokens} loading={nftState.loading} error={nftState.error} confirmed={!!nftState.data}/></HoldingsSection></>:null}
    <h2>Transactions</h2>
    {walletNetwork==='krc20'&&resolved.startsWith('kaspa:')?<><div className="flex gap-3 my-3">{['all','krc20','kcc20'].map(t=><button aria-pressed={activityTab===t} key={t} onClick={()=>setActivityTab(t)}>{t==='all'?'All':t.toUpperCase()}</button>)}</div>{activityTab==='all'?<ChainActivity key={resolved} address={resolved}/>:<WalletTransactionPanel key={resolved+activityTab} network={walletNetwork} address={resolved} standard={activityTab==='kcc20'?'kcc20':undefined}/>}</>:data?<WalletTransactionPanel network={walletNetwork} address={resolved}/>:<p>Resolving transaction history…</p>}
    {labelModalOpen?<WalletLabelModal address={resolved} draft={labelDraft} currentLabel={personalLabel} onChange={setLabelDraft} onClose={()=>setLabelModalOpen(false)} onDelete={()=>{removeLabel(resolved);setLabelModalOpen(false)}} onSave={()=>{if(labelDraft.trim())setLabel(resolved,labelDraft);else removeLabel(resolved);setLabelModalOpen(false)}}/>:null}
  </section>;
}

function WalletLabelBadge({ label }: { label: ResolvedWalletLabel }) {
  const className = label.source === "global"
    ? "border-amber-300/70 bg-amber-300/10 text-amber-200 shadow-[0_0_12px_rgba(252,211,77,0.16)]"
    : "border-kaspa-primary/50 bg-kaspa-primary/10 text-kaspa-primary";
  return <span className={`rounded-md border px-2 py-1 text-xs font-bold ${className}`}>{label.label}</span>;
}

function formatWalletTokenBalance(balance: number|null, network: WalletNetwork) {
  if (network !== "krc20" && balance!==null && balance > 0 && balance < 0.0001) {
    return "< 0.0001";
  }
  return formatTokenAmount(balance);
}

function WalletLabelModal({
  address,
  currentLabel,
  draft,
  onChange,
  onClose,
  onDelete,
  onSave
}: {
  address: string;
  currentLabel: string | null;
  draft: string;
  onChange: (value: string) => void;
  onClose: () => void;
  onDelete: () => void;
  onSave: () => void;
}) {
  const [confirmDelete, setConfirmDelete] = useState(false);

  if (confirmDelete && currentLabel) {
    return (
      <div className="fixed inset-0 z-[80] flex items-center justify-center bg-kaspa-background/80 px-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="delete-wallet-label-title">
        <div className="kaspa-panel w-full max-w-md rounded-md p-5 shadow-[0_20px_80px_rgba(0,0,0,0.45)]">
          <div className="flex items-start gap-3">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-red-300/50 bg-red-400/10 text-red-300">
              <AlertTriangle className="h-5 w-5" aria-hidden="true" />
            </div>
            <div className="min-w-0">
              <h2 id="delete-wallet-label-title" className="text-lg font-bold text-kaspa-text">Delete label?</h2>
              <p className="mt-2 text-sm leading-6 text-kaspa-muted">
                This removes the saved label <span className="font-bold text-kaspa-text">{currentLabel}</span> from this browser. The wallet address remains untouched.
              </p>
              <p className="mt-2 break-all font-mono text-xs text-kaspa-muted">{address}</p>
            </div>
          </div>
          <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button type="button" onClick={() => setConfirmDelete(false)} className="focus-ring h-10 rounded-md border border-kaspa-border px-4 text-sm font-bold text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
              Cancel
            </button>
            <button type="button" onClick={onDelete} className="focus-ring inline-flex h-10 items-center justify-center gap-2 rounded-md border border-red-300/70 bg-red-400/10 px-4 text-sm font-bold text-red-200 hover:bg-red-400/20">
              <Trash2 className="h-4 w-4" aria-hidden="true" /> Delete
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/70 px-4 backdrop-blur-sm">
      <div className="kaspa-panel w-full max-w-lg rounded-md p-5 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-lg font-bold text-kaspa-text">Add label</h2>
            <p className="mt-2 break-all font-mono text-xs text-kaspa-muted">{address}</p>
          </div>
          <button type="button" onClick={onClose} className="focus-ring rounded-md border border-kaspa-border px-3 py-2 text-sm font-bold text-kaspa-muted hover:text-kaspa-text">Close</button>
        </div>
        <label className="mt-5 block text-sm font-bold text-kaspa-text" htmlFor="wallet-label-input">Label</label>
        <input
          id="wallet-label-input"
          value={draft}
          onChange={(event) => onChange(event.target.value)}
          placeholder="Binance, Husband, Trading Wallet..."
          className="focus-ring mt-2 h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background px-3 text-sm text-kaspa-text outline-none"
          autoFocus
        />
        <div className="mt-5 flex flex-wrap justify-between gap-3">
          {currentLabel ? (
            <button type="button" onClick={() => setConfirmDelete(true)} className="focus-ring rounded-md border border-red-400/50 px-4 py-2 text-sm font-bold text-red-200 hover:bg-red-400/10">Delete label</button>
          ) : <div />}
          <div className="flex gap-3">
            <button type="button" onClick={onClose} className="focus-ring rounded-md border border-kaspa-border px-4 py-2 text-sm font-bold text-kaspa-muted hover:text-kaspa-text">Cancel</button>
            <button type="button" onClick={onSave} className="focus-ring rounded-md border border-kaspa-primary bg-kaspa-primary px-4 py-2 text-sm font-bold text-kaspa-background shadow-kaspa">Save label</button>
          </div>
        </div>
      </div>
    </div>
  );
}

function WalletTransactionPanel({ network, address,standard }: { network: WalletNetwork; address: string;standard?:string }) {
  const [transactions, setTransactions] = useState<TokenTransaction[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setTransactions([]);
    setNextCursor(null);
    setLoading(true);
    setError(null);

    getWalletTransactions(network, address,null,standard)
      .then((envelope) => {
        if (!active) return;
        setTransactions(envelope.data.transactions);
        setNextCursor(envelope.data.next_cursor);
        setLoading(false);
      })
      .catch((requestError: Error) => {
        if (!active) return;
        setError(requestError.message);
        setLoading(false);
      });

    const timer=standard==="kcc20"?window.setInterval(()=>{
      getWalletTransactions(network,address,null,standard).then(envelope=>{
        if(active){
          setTransactions(current=>mergeTransactions(envelope.data.transactions,current).sort((a,b)=>Date.parse(b.timestamp)-Date.parse(a.timestamp)));
          setNextCursor(current=>current||envelope.data.next_cursor);
        }
      }).catch(()=>undefined);
    },30000):null;
    return () => {
      active = false;
      if(timer)window.clearInterval(timer);
    };
  }, [network, address,standard]);

  function loadMore() {
    if (!nextCursor || loadingMore) {
      return;
    }
    setLoadingMore(true);
    setError(null);
    getWalletTransactions(network, address, nextCursor,standard)
      .then((envelope) => {
        setTransactions((current) => mergeTransactions(current, envelope.data.transactions));
        setNextCursor(envelope.data.next_cursor);
      })
      .catch((requestError: Error) => setError(requestError.message))
      .finally(() => setLoadingMore(false));
  }

  if (loading) {
    return <div className="kaspa-panel h-52 animate-pulse rounded-md" />;
  }

  return (
    <div className="space-y-3">
      {error ? <div className="rounded-md border border-red-400/50 bg-red-400/10 px-4 py-3 text-sm text-red-200">{error}</div> : null}
      <TxTable transactions={transactions} emptyMessage="No token transactions found" />
      {nextCursor ? (
        <div className="flex justify-center">
          <button type="button" onClick={loadMore} disabled={loadingMore} className="focus-ring h-10 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary shadow-kaspa transition hover:bg-kaspa-primary hover:text-kaspa-background disabled:cursor-not-allowed disabled:opacity-40">
            {loadingMore ? "Loading..." : "Load more transactions"}
          </button>
        </div>
      ) : null}
    </div>
  );
}

function mergeTransactions(current: TokenTransaction[], next: TokenTransaction[]) {
  const seen = new Set(current.map((transaction) => transaction.id));
  return [...current, ...next.filter((transaction) => !seen.has(transaction.id))];
}

