export const NEXUS_DURATIONS:number[];
export function buildInternalNexusChallenge(address:string,nonce:string,issuedAt:string,expiresAt:string):string;
export function validateOffer(input:any):{collectionId:string;tokenId:string;amountKas:string;durationDays:number};
export function createNexusToken(address:string,secret:string,now?:number):string;
export function readNexusToken(token:string|undefined,secret:string,now?:number):string|null;
