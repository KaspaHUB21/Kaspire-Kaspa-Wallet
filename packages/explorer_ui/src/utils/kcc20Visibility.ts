// View policy only: balances and saved favorite IDs are never deleted.
export const retiredKcc20=new Set([
 '14ec7542182a0408f78f8ea4ad7ac135e7f41305c61e0053a67a2828e585984d',
 '69001bc75394f3baf1863aad014c35275371935fad29e1d3a114aa23a4db721a'
]);
type Identity={id?:string;token_id?:string;contract_address?:string;covenant_id?:string;symbol?:string|null;claimed_ticker?:string|null;image_url?:string|null};
export function displayableKcc20(token:Identity):boolean {
 const cid=(token.contract_address||token.covenant_id||token.token_id||token.id||'').replace(/^kcc20-/i,'').toLowerCase();
 if(retiredKcc20.has(cid))return false;
 const symbol=(token.symbol||token.claimed_ticker||'').trim();
 // A bare standard/CID placeholder is not an identified asset. Named tokens
 // remain visible even without an image or published decimals.
 return !!symbol&&!/^KCC[- ]?20(?:\s|$)/i.test(symbol)||!!token.image_url;
}
