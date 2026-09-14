// Deterministic UI fixture only. No keys, signing operations or external requests.
const fixtureAddress = 'kaspa:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';
const fixtureState = {
  hasVault: true, locked: false, recoveryVerified: true, network: 'mainnet',
  selectedAddress: fixtureAddress,
  addresses: [{address: fixtureAddress, name: 'HUB21 Test Wallet', path: 'Watch only', watchOnly: true}],
  contacts: [], permissions: {},
  settings: {theme:'hub21', hideBalances:false, currency:'USD', autoLockMinutes:15, showSubwallets:true},
};
const fixtureAssets = {
  tokens: ['zulu','Kasbtc','burtle'].map(symbol=>({symbol,raw_balance:'963909167959',decimals:8})),
  kcc20: ['zeta','BURTLE','Alpha'].map((symbol,index)=>({symbol,rawBalance:'100000000',decimals:8,covenantId:`fixture-${index}`})),
  krc721: ['zombies','Burtle','ANGELS'].map(symbol=>({symbol,balance:3})),
  domains: ['zulu.kas','alpha.kas','beta.kas'].map(name=>({name})),
};
window.chrome ??= {};
window.chrome.runtime = {
  getManifest:()=>({version:'0.4.7.1'}),
  sendMessage: async message => {
    let result;
    switch(message.command) {
      case 'status': result=fixtureState; break;
      case 'setSettings': Object.assign(fixtureState.settings,message.settings);result=fixtureState.settings;break;
      case 'setNetwork': fixtureState.network=message.network;result=fixtureState;break;
      case 'balanceSnapshot': case 'coreSnapshot': result={address:fixtureAddress,balanceKas:7783.8699,utxoCount:0,utxos:[],nativeSymbol:fixtureState.network==='igra'?'iKAS':'KAS',tokens:[{symbol:'ZED',balance:'3'},{symbol:'ALPHA',balance:'2'}]};break;
      case 'assetCategory': result=fixtureAssets[message.category];break;
      case 'market': result={kasUsd:.0346,rate:1,currency:'USD'};break;
      case 'tokenMarket': result={priceKas:.869,priceUsd:.03,explorerUrl:'https://example.invalid/token'};break;
      case 'evmAddress': result='0x'+'1'.repeat(40);break;
      case 'storeUpdateStatus': result={installedVersion:'0.4.7.1',status:'no_update'};break;
      case 'lock': fixtureState.locked=true;result=true;break;
      case 'nftCollection': result={nfts:[],total:0,nextOffset:null};break;
      default: result=[];
    }
    return {result:structuredClone(result)};
  },
};
window.chrome.tabs={create:()=>{}};
