import {createHmac, timingSafeEqual, randomBytes} from 'node:crypto';
export const NEXUS_DURATIONS = [7,14,21,30,60];
export function buildInternalNexusChallenge(address,nonce,issuedAt,expiresAt) {
  return `Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: ${address}\nNonce: ${nonce}\nIssued at: ${issuedAt}\nExpires at: ${expiresAt}\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.`;
}
export function validateOffer(input) {
  if (!/^[a-zA-Z0-9_-]{1,32}$/.test(input.collectionId ?? '') || !/^\d{1,20}$/.test(input.tokenId ?? '')) throw Error('Invalid NFT reference.');
  if (typeof input.amountKas !== 'string' || !/^\d{1,8}(\.\d{1,8})?$/.test(input.amountKas) || Number(input.amountKas) <= 0 || Number(input.amountKas) > 90_000_000) throw Error('Enter a positive KAS amount with up to 8 decimal places.');
  if (!NEXUS_DURATIONS.includes(input.durationDays) || input.acknowledgedNonBinding !== true) throw Error('Confirm the non-binding offer and select a valid duration.');
  return {collectionId:input.collectionId,tokenId:input.tokenId,amountKas:input.amountKas,durationDays:input.durationDays};
}
export function createNexusToken(address,secret,now=Date.now()) {
  const payload=Buffer.from(JSON.stringify({address,issuedAt:now,nonce:randomBytes(16).toString('hex')})).toString('base64url');
  const sig=createHmac('sha256',secret).update('kaspire-nexus-v1\0'+payload).digest('base64url');
  return payload+'.'+sig;
}
export function readNexusToken(token,secret,now=Date.now()) {
  if(typeof token!=='string'||token.length>1024)return null;
  const parts=token.split('.');if(parts.length!==2)return null;
  const sig=createHmac('sha256',secret).update('kaspire-nexus-v1\0'+parts[0]).digest('base64url');
  if(parts[1].length!==sig.length||!timingSafeEqual(Buffer.from(sig),Buffer.from(parts[1])))return null;
  try{const p=JSON.parse(Buffer.from(parts[0],'base64url').toString());
    return /^kaspa:[a-z0-9]{40,80}$/.test(p.address)&&Number.isFinite(p.issuedAt)&&p.issuedAt<=now&&now-p.issuedAt<7*86400000?p.address:null;
  }catch{return null;}
}
