import {createHmac,timingSafeEqual} from 'node:crypto';
export const families={krc20:'p2p-v2',krc721:'krc721-orders-v2',kns:'kns-orders'};
export function family(kind){if(!Object.hasOwn(families,kind))throw Error('Unsupported marketplace');return families[kind];}
// Match the Token Explorer's KRC20 ranking (not the partner API's arbitrary
// market-data order). Warning tokens and unusual caps follow verified tokens.
export function rankedKrc20(tokens){
  const n=(t,k)=>Number(t[k])||0;
  const warning=t=>t.symbol?.toUpperCase()==='DAGAS';
  const volume=t=>n(t,'volume_30d_usd')>0||n(t,'volume_7d_usd')>0?n(t,'volume_30d_usd'):
    ((t.volume_7d_available===false&&t.volume_30d_available===false)||(t.markets??[]).some(m=>m.type==='DEX'&&m.volume_7d_available===false&&m.volume_30d_available===false&&n(m,'volume_24h_usd')>0))?n(t,'volume_24h_usd'):0;
  const unusual=t=>warning(t)||(t.symbol?.toUpperCase()!=='ZEAL'&&(!!t.unusual_market_cap||(n(t,'market_cap_usd')>1000000&&n(t,'volume_24h_usd')<500&&n(t,'volume_30d_usd')<2000)));
  return tokens.filter(t=>/^[A-Z0-9]{1,10}$/.test(t.symbol??'')).slice().sort((a,b)=>
    Number(warning(a))-Number(warning(b))||Number(unusual(a))-Number(unusual(b))||
    Number(!!b.verified)-Number(!!a.verified)||
    ((!a.verified&&!b.verified)?volume(b)-volume(a)||n(b,'volume_30d_usd')-n(a,'volume_30d_usd')||n(b,'volume_7d_usd')-n(a,'volume_7d_usd')||n(b,'volume_24h_usd')-n(a,'volume_24h_usd'):0)||
    n(b,'market_cap_usd')-n(a,'market_cap_usd')||a.symbol.localeCompare(b.symbol));
}
// Exact default KRC721 ordering used by Token Explorer's ExplorerPage.
export function rankedKrc721(tokens){
  const n=(t,k)=>Number(t[k])||0;
  const seen=new Set();
  return tokens.filter(t=>/^[A-Z0-9]{1,10}$/.test(t.symbol??'')&&!seen.has(t.symbol)&&seen.add(t.symbol)).slice().sort((a,b)=>
    n(b,'volume_30d_kas')-n(a,'volume_30d_kas')||n(b,'volume_7d_kas')-n(a,'volume_7d_kas')||
    n(b,'volume_24h_kas')-n(a,'volume_24h_kas')||n(b,'all_time_volume_kas')-n(a,'all_time_volume_kas')||a.symbol.localeCompare(b.symbol));
}
export function wallet(value){if(typeof value!=='string'||!/^kaspa:[a-z0-9]{40,80}$/.test(value))throw Error('A mainnet wallet is required');return value;}
export function page(value,max=1000000){const n=Number(value??0);if(!Number.isSafeInteger(n)||n<0||n>max)throw Error('Invalid page');return n;}
export function orderId(value){if(!/^[a-f0-9]{24}$/.test(value??''))throw Error('Invalid order ID');return value;}
export function historyFilters(role='all'){
  if(!['all','seller','buyer','sales'].includes(role))throw Error('Invalid history role');
  return {isSeller:role!=='buyer',isBuyer:role!=='seller'&&role!=='sales',...(role==='seller'?{statuses:['LISTED_FOR_SALE']}:role==='sales'?{statuses:['COMPLETED']}: {})};
}
// KaspaCom validates the original seller's DAA metadata even when our node
// assigns a slightly different score. DAA is not a transaction/sighash field.
// Match the exact outpoint/script/amount before restoring that metadata only.
export function sellerTransportMetadata(signedBuyerPskt,psktSeller){
  const tx=JSON.parse(signedBuyerPskt), seller=JSON.parse(psktSeller);
  const a=tx.inputs?.[0],b=seller.inputs?.[0];
  if(!a||!b||a.transactionId!==b.transactionId||a.index!==b.index||
    a.utxo?.scriptPublicKey!==b.utxo?.scriptPublicKey||String(a.utxo?.amount)!==String(b.utxo?.amount)||
    a.utxo?.isCoinbase!==false||b.utxo?.isCoinbase!==false)throw Error('Seller UTXO metadata differs from the signed listing');
  const score=String(b.utxo.blockDaaScore);
  if(!/^\d{1,20}$/.test(score)||BigInt(score)>2n**64n-1n)throw Error('Invalid seller DAA metadata');
  a.utxo.blockDaaScore=b.utxo.blockDaaScore;
  return JSON.stringify(tx);
}
export function purchaseOutcome(response){
  if(response?.success===true)return response;
  // Forward only bounded diagnostic fields, never PSKT/credentials or the
  // upstream response as a whole. A refusal must not become a successful sale.
  const raw=response?.errorMessage??response?.message??response?.error?.message??(typeof response?.error==='string'?response.error:null);
  const detail=typeof raw==='string'?raw.replace(/[\x00-\x1f]/g,' ').slice(0,240):'No reason supplied by the KaspaCom API';
  const code=Number.isSafeInteger(response?.errorCode)?` (code ${response.errorCode})`:'';
  throw Error(`KaspaCom refused the purchase${code}: ${detail}. The signed transaction remains saved; do not create a second purchase.`);
}
export function browseBody(kind,q){family(kind);const sort=q.get('sort')??'recent';if(!['recent','low','high',...(kind==='krc721'?['rankLow','rankHigh']:[])].includes(sort))throw Error('Invalid sort');const search=(q.get('search')??'').trim();if(search.length>100)throw Error('Search is too long');
  const filters={completedOrders:false,onlyDecentralize:true};if(kind==='kns'&&search){filters.assetsSearch=true;filters.assets=[search.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')];}
  let traits={};if(q.has('traits')){if(kind!=='krc721'||q.get('traits').length>4096)throw Error('Invalid traits');traits=JSON.parse(q.get('traits'));if(!traits||typeof traits!=='object'||Array.isArray(traits)||Object.keys(traits).length>32||Object.entries(traits).some(([k,v])=>k.length>100||typeof v!=='string'||v.length>200))throw Error('Invalid traits');}
  return {sort:kind==='krc20'?{direction:'asc',field:'pricePerToken'}:{direction:['low','rankLow'].includes(sort)?'asc':'desc',field:sort.startsWith('rank')?'rarityRank':sort==='recent'?'createdAt':'totalPrice'},pagination:{limit:10,offset:page(q.get('offset'))},completedOrders:false,onlyDecentralize:true,filters,...(kind==='krc721'?{traits}:{})};
}
export function issueToken(address,secret,now=Date.now()){const p=Buffer.from(JSON.stringify({address,at:now})).toString('base64url');return p+'.'+createHmac('sha256',secret).update('kaspacom-wallet-v1\0'+p).digest('base64url');}
export function readToken(token,secret,now=Date.now()){if(typeof token!=='string'||token.length>1024)return null;const [p,s,...extra]=token.split('.');if(extra.length||!s)return null;const expected=createHmac('sha256',secret).update('kaspacom-wallet-v1\0'+p).digest('base64url');if(s.length!==expected.length||!timingSafeEqual(Buffer.from(s),Buffer.from(expected)))return null;try{const v=JSON.parse(Buffer.from(p,'base64url'));return Number.isFinite(v.at)&&v.at<=now&&now-v.at<3600000?wallet(v.address):null;}catch{return null;}}
export function writeBody(kind,action,b){family(kind);if(!b||Array.isArray(b)||typeof b!=='object')throw Error('Invalid request');if(action==='create'){
  if(!Number.isFinite(b.totalPrice)||b.totalPrice<=0||b.totalPrice>90000000||Math.abs(b.totalPrice*100-Math.round(b.totalPrice*100))>0.000001)throw Error('Enter a positive price with at most two decimals');
  if(typeof b.psktSeller!=='string'||b.psktSeller.length>128*1024)throw Error('Invalid seller PSKT');const tx=JSON.parse(b.psktSeller);if(tx.inputs?.length!==1||tx.outputs?.length!==1)throw Error('Unexpected seller PSKT shape');
  const result={totalPrice:b.totalPrice,psktSeller:b.psktSeller};if(kind==='kns'){if(!/^[a-f0-9]{64}i0$/.test(b.assetId??''))throw Error('Invalid KNS ID');result.assetId=b.assetId;}else{if(!/^[A-Z0-9]{1,10}$/.test(b.ticker??''))throw Error('Invalid ticker');result.ticker=b.ticker;if(kind==='krc721'){if(!/^\d{1,20}$/.test(String(b.tokenId??'')))throw Error('Invalid NFT ID');result.tokenId=String(b.tokenId);}else{if(!Number.isFinite(b.quantity)||b.quantity<=0)throw Error('Invalid quantity');result.quantity=b.quantity;}}return result;
  }if(action==='buy'){if(typeof b.signedBuyerPskt!=='string'||b.signedBuyerPskt.length>512*1024)throw Error('Invalid buyer PSKT');JSON.parse(b.signedBuyerPskt);return {signedBuyerPskt:b.signedBuyerPskt};}
  if(action==='verify'){if(!/^[a-f0-9]{64}$/.test(b.transactionId??''))throw Error('Invalid transaction ID');return {transactionId:b.transactionId};}throw Error('Unsupported action');}
