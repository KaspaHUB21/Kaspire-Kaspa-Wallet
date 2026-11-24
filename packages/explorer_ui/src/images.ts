const explorer='https://kaspatoken.kaslab.space',nexus='https://kaspanftnexus.com';
export function krc20Logo(symbol:string):string|undefined {const ticker=symbol.toLowerCase();return /^[a-z0-9_-]{1,32}$/.test(ticker)?'https://kaspire.kaslab.space/api/token-logos/krc20/'+ticker:undefined;}
export function kcc20LogoFallback(cid:string|undefined):string|undefined {return cid&&/^[a-f0-9]{64}$/i.test(cid)?'https://kascov.io/img/mainnet/'+cid.toLowerCase():undefined;}
export function publicImage(source:string|null|undefined):string|undefined {
 if(!source)return;
 const nft=/^\/api\/nft-images\/([^/?]+)\/(\d+)/.exec(source);
 if(nft)return nftImage(decodeURIComponent(nft[1]),nft[2]);
 try{const u=new URL(source,explorer);if(u.protocol==='https:'&&!u.username&&!u.password)return u.href;}catch{}
}
export function nftImage(ticker:string,id:string):string {
 return ticker.toUpperCase()==='HASH'?nexus+'/assets/collections/hash/'+encodeURIComponent(id)+'.png':nexus+'/api/nft-images/'+encodeURIComponent(ticker.toUpperCase())+'/'+encodeURIComponent(id);
}
