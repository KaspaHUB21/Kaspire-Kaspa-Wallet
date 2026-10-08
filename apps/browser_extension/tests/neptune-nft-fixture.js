fixtureState.settings.theme='neptune';
chrome.runtime.connect=()=>({onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(){},disconnect(){}});
chrome.runtime.getURL=path=>new URL(path,location.href).href;
fixtureState.addresses[0].name='Neptune Test Wallet';
fixtureAssets.krc721=fixtureAssets.krc721.map(row=>({...row,image_url:'https://kaspire.kaslab.space/krc721-read-v1/images/KASZOMBIES/55'}));
const nftRows=Array.from({length:12},(_,index)=>({ticker:'KASZOMBIES',tokenId:String(55+index),imageUrl:'https://kaspire.kaslab.space/krc721-read-v1/images/KASZOMBIES/'+(55+index),rarityRank:114+index,priceSompi:(index+10)*100000000,seller:'kaspa:seller-fixture',listingTransactionId:index.toString(16).padStart(64,'0'),status:'active',traits:{Background:'Blue'}}));
const baseSend=chrome.runtime.sendMessage;
let nexusRead=false,nexusOfferStatus='OPEN';
chrome.runtime.sendMessage=async message=>{
  window.lastNftRequest=message;
  switch(message.command){
    case 'nexusStatus': case 'nexusConnect': return {result:{connected:true}};
    case 'nexusPoll':return {result:{connected:true,notifications:nexusRead?[]:[{id:'notice',readAt:null,payloadJson:{title:'New private offer',collectionId:'kaszombies',tokenId:'55'}}]}};
    case 'nexusRequest': {
      window.lastNexusRequest=message;
      const path=message.path;
      if(path==='search')return {result:message.query.q.includes('#')?{kind:'nft',collectionId:'kaszombies',tokenId:'55'}:{kind:'collection',collectionId:'kaszombies'}};
      if(path.startsWith('collection/'))return {result:{tokens:nftRows.slice(0,2),catalog:[{traitType:'Background',values:[{value:'Blue',count:12,rarity:2.1}]}],nextOffset:null}};
      if(path.startsWith('nft/'))return {result:{collectionId:'kaszombies',tokenId:'55',imageUrl:nftRows[0].imageUrl,rarityRank:114,currentOwnerWallet:'kaspa:another-owner',listingStatus:'LISTED',listingPriceSompi:null,bestOffers:[{currentAmountSompi:'1000000000',status:'OPEN'}],attributes:[]}};
      if(path==='offers/active')return {result:{offers:nftRows.slice(0,10).map(row=>({...row,collectionId:'kaszombies',amountKas:'10',statusLabel:'Open'})),nextOffset:null}};
      if(path==='dashboard/received')return {result:[{id:'ctestoffer0123456789',nftCache:{collectionId:'kaszombies',tokenId:'55'},currentAmountSompi:'1000000000',status:nexusOfferStatus,expiresAt:new Date(Date.now()+86400000).toISOString(),revisions:[]}]};
      if(path==='dashboard/notifications')return {result:[{id:'notice',createdAt:new Date().toISOString(),readAt:null,payloadJson:{title:'New private offer',message:'NFT received an offer for 10 KAS.',collectionId:'kaszombies',tokenId:'55'}}]};
      if(path==='notifications/read'){nexusRead=true;return {result:{ok:true}};}
      if(path.includes('agree-to-relist')){nexusOfferStatus='AGREED_WAITING_RELIST';return {result:{ok:true}};}
      return {result:{ok:true}};
    }
    case 'nftMarketBrowse':{const offset=message.params?.offset??0;return {result:{offers:nftRows.slice(offset,offset+10),nextOffset:offset===0?10:null,collections:['KASZOMBIES','ZMEMES'],traitOptions:{Background:['Blue','Red']}}};}
    case 'nftMarketCollections':return {result:['KASZOMBIES','ZMEMES']};
    case 'nftMarketOwned':return {result:{nfts:nftRows.slice(0,2).map(row=>({...row,status:{state:'owned'}})),next:null}};
    case 'nftMarketListings':return {result:{records:[
      {...nftRows[0],seller:fixtureAddress,localId:'test-listing',stage:'complete',published:true},
      {...nftRows[1],seller:fixtureAddress,status:'cancelled'},
      {...nftRows[2],seller:fixtureAddress,status:'sold'},
      {...nftRows[3],seller:fixtureAddress,status:'active'},
      {...nftRows[4],seller:fixtureAddress,localId:'pending-test',stage:'reveal',status:'pending'},
    ],pendingBroadcast:false}};
    case 'nftMarketPublishPending':return {result:true};
    case 'nftCollection':return {result:{nfts:nftRows.slice(0,2),total:2,nextOffset:null}};
    case 'receiveAccount':return {result:{primaryAddress:fixtureAddress,receiveAddress:fixtureAddress,rotationSupported:false,addresses:[]}};
    default:return baseSend(message);
  }
};
