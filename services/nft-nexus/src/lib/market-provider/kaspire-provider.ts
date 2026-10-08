import {privateToken} from './private-indexer';
import {getOrFetchRarityRank} from './rarity-cache';
import {getCollectionInfo,isBlacklistedCollection} from './collections';
import type {MarketProvider,NftReference,NftSnapshot} from './types';
// Read protocol listing state from the indexer, never marketplace web pages.
// Prices/settlement are supplied only by Kaspire's own PSKT directory.
export class KaspireMarketProvider implements MarketProvider {
 async parseMarketUrl(value:string):Promise<NftReference|null> {
  const url=new URL(value);if(url.origin!=='https://kaspire.kaslab.space')return null;
  const match=url.pathname.match(/^\/nexus\/nft\/([A-Za-z0-9_-]+)\/(\d+)$/);
  return match?{collectionId:match[1],tokenId:match[2]}:null;
 }
 async getNftSnapshot(ref:NftReference):Promise<NftSnapshot|null> {
  const collection=getCollectionInfo(ref.collectionId);if(!collection)return null;
  const [token,rank]=await Promise.all([privateToken(collection.ticker,ref.tokenId),getOrFetchRarityRank(collection.collectionId,ref.tokenId)]);
  if(!token)return null;
  return {collectionId:collection.collectionId,collectionName:collection.displayName,tokenId:ref.tokenId,name:`${collection.ticker} #${ref.tokenId}`,imageUrl:`https://kaspire.kaslab.space/krc721-read-v1/images/${collection.ticker}/${ref.tokenId}`,ownerWallet:token.owner??null,marketUrl:this.getCanonicalMarketUrl(ref),listingStatus:token.status?.state==='listed'?'LISTED':'UNLISTED',listingPriceSompi:null,listingId:token.status?.listingTxId??null,rarityRank:rank,checkedAt:new Date()};
 }
 getCanonicalMarketUrl(ref:NftReference){return `https://kaspire.kaslab.space/nexus/nft/${encodeURIComponent(ref.collectionId)}/${encodeURIComponent(ref.tokenId)}`;}
 async isSupportedCollection(id:string){return !isBlacklistedCollection(id);}
}
