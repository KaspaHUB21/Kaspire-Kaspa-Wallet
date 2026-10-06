fixtureState.settings.theme='neptune';
chrome.runtime.connect=()=>({onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(){},disconnect(){}});
chrome.runtime.getURL=path=>new URL(path,location.href).href;
fixtureState.addresses[0].name='Neptune Test Wallet';
fixtureAssets.krc721=fixtureAssets.krc721.map(row=>({...row,image_url:'https://kaspire.kaslab.space/krc721-read-v1/images/KASZOMBIES/55'}));
const nftRows=Array.from({length:12},(_,index)=>({ticker:'KASZOMBIES',tokenId:String(55+index),imageUrl:'https://kaspire.kaslab.space/krc721-read-v1/images/KASZOMBIES/'+(55+index),rarityRank:114+index,priceSompi:(index+10)*100000000,seller:'kaspa:seller-fixture',listingTransactionId:index.toString(16).padStart(64,'0'),status:'active',traits:{Background:'Blue'}}));
const baseSend=chrome.runtime.sendMessage;
chrome.runtime.sendMessage=async message=>{
  window.lastNftRequest=message;
  switch(message.command){
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
