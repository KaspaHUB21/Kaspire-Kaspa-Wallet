export const PROVIDER_CHANNEL="kaspire:provider:v1";
export const providerMethods=["requestAccounts","getAccounts","getNetwork","switchNetwork","getPublicKey","getBalance","getUtxoEntries","disconnect","signMessage","sendKaspa","sendKRC20","sendKCC20","signPskt","pushTx","signPolicyTransaction","transferKRC721","transferKNS"] as const;
export type ProviderMethod=typeof providerMethods[number]; export type KaspaNetwork="mainnet"|"testnet-10";
export interface ProviderRequest{channel:typeof PROVIDER_CHANNEL;direction:"request";id:string;method:ProviderMethod;params?:unknown}
export interface ProviderResponse{channel:typeof PROVIDER_CHANNEL;direction:"response";id:string;result?:unknown;error?:{code:number;message:string}}
export interface ProviderEvent{channel:typeof PROVIDER_CHANNEL;direction:"event";event:"accountsChanged"|"networkChanged"|"disconnect";data:unknown}
export function isProviderRequest(value:unknown):value is ProviderRequest{if(!value||typeof value!=="object")return false;const item=value as Partial<ProviderRequest>;if(item.channel!==PROVIDER_CHANNEL||item.direction!=="request"||typeof item.id!=="string"||item.id.length<1||item.id.length>128||!providerMethods.includes(item.method as ProviderMethod))return false;try{return JSON.stringify(value).length<=1_048_576}catch{return false}}
