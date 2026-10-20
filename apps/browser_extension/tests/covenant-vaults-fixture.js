// UI-only fixture. Native/WASM cryptography is tested separately without mocks.
fixtureState.selectedAddress=vaultNative.cases[0].request.sender;
fixtureState.addresses=[{address:fixtureState.selectedAddress,name:'Vault UI fixture',walletId:'fixture',path:'private-key',watchOnly:false}];
fixtureState.settings.theme=new URL(location.href).searchParams.get('theme')??'midnight';
let vaultItems=[],vaultPendingApproval=null,vaultResolve=null,vaultPrepared=null;
window.vaultFixtureMode='confirmed';window.vaultFixtureSigned=0;window.vaultDownloads=0;
const vaultBaseSend=chrome.runtime.sendMessage;
chrome.runtime.getURL=path=>new URL(path,location.href).href;
chrome.runtime.connect=()=>{
  const listeners=[],disconnected=[];let closed=false;
  return {onMessage:{addListener:fn=>listeners.push(fn)},onDisconnect:{addListener:fn=>disconnected.push(fn)},postMessage:message=>{Promise.resolve(chrome.runtime.sendMessage(message)).then(response=>{if(!closed)listeners.forEach(fn=>fn(response));});},disconnect:()=>{if(!closed){closed=true;disconnected.forEach(fn=>fn());}}};
};
chrome.runtime.sendMessage=async message=>{
  switch(message.command){
    case 'covenantVaultSaved':return {result:structuredClone(vaultItems)};
    case 'covenantVaultDaa':return {result:2000};
    case 'covenantVaultRefresh':return {result:{items:structuredClone(vaultItems),error:''}};
    case 'covenantVaultPrepare':{
      const found=vaultNative.cases.find(c=>c.request.action===message.action&&(message.kind??c.request.terms.kind)===c.request.terms.kind);
      vaultPrepared={id:'vault-review',review:structuredClone(found.review)};return {result:vaultPrepared};
    }
    case 'covenantVaultExport':return {result:{envelope:vaultNative.sealed,covenantId:vaultPrepared?.review.covenantId??vaultItems[0].record.covenantId}};
    case 'covenantVaultSubmit':{
      vaultPendingApproval={id:'vault-approval',origin:'Kaspire Wallet',title:'Create covenant vault',description:'Rebuilt by Rust security core',details:['Amount: 1 KAS','Network fee: 0.004 KAS'],rawJson:{profile:'kaspire-covenant-vault-v1'}};
      return new Promise(resolve=>{vaultResolve=resolve;});
    }
    case 'pendingApproval':return {result:vaultPendingApproval};
    case 'resolveWalletApproval':{
      const finish=vaultResolve;vaultPendingApproval=null;vaultResolve=null;
      if(!message.approved){finish({error:{message:'Vault transaction rejected. Nothing was signed.'}});return {result:true};}
      window.vaultFixtureSigned++;
      const record={...vaultPrepared.review.record,status:'locked'};
      if(window.vaultFixtureMode==='interrupted'){
        vaultItems=[{record:{...record,status:'pending'},pending:{transactionId:record.transactionId,submitted:false,action:'create',wrpcJson:'fixture-only'}}];
        finish({error:{message:'Submission interrupted. Signed transaction saved.'}});
      }else{vaultItems=[{record}];finish({result:{transactionId:record.transactionId,confirmed:true}});}
      return {result:true};
    }
    case 'covenantVaultResume':vaultItems=vaultItems.map(i=>({record:{...i.record,status:'locked'}}));return {result:{transactionId:vaultItems[0].record.transactionId,confirmed:true}};
    case 'covenantVaultImport':vaultItems=[{record:{...vaultNative.record,status:'locked'}}];return {result:vaultNative.record};
    case 'covenantVaultDiscover':return {result:0};
    case 'nexusPoll':return {result:{connected:false,notifications:[]}};
    case 'nexusStatus':return {result:{connected:false}};
    default:return vaultBaseSend(message);
  }
};
const vaultOriginalClick=HTMLAnchorElement.prototype.click;
HTMLAnchorElement.prototype.click=function(){if(this.download){window.vaultDownloads++;return;}return vaultOriginalClick.call(this);};
window.vaultFixtureOpened=()=>{vaultItems=vaultItems.map(i=>({record:{...i.record,status:'opened'}}));};
