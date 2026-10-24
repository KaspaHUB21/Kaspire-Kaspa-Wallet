import type {PanelApproval} from '../background/sidePanelApprovals';

/** No heartbeat, session activity update or auto-lock override. */
export function startSidePanelApprovals(present:(view:PanelApproval,signal:AbortSignal)=>Promise<boolean>) {
  if(location.pathname!=='/sidepanel.html')return;
  let stopped=false,port:chrome.runtime.Port|undefined,retry:ReturnType<typeof setTimeout>|undefined;
  let active:{id:string;cancel:AbortController}|undefined;
  const connect=()=>{
    if(stopped)return;
    const current=chrome.runtime.connect({name:'wallet-sidepanel-approvals'});port=current;
    current.onMessage.addListener(message=>{
      if(current!==port)return;
      if(message?.kind==='ready'){document.documentElement.dataset.panelApprovalReady='true';return;}
      if(message?.kind==='cancel'&&active&&message.id===active.id){active.cancel.abort();active=undefined;return;}
      if(message?.kind!=='approval'||typeof message.view?.id!=='string')return;
      active?.cancel.abort();
      const pending={id:message.view.id,cancel:new AbortController()};active=pending;
      void present(message.view,pending.cancel.signal).catch(()=>false).then(approved=>{
        if(stopped||current!==port||active!==pending||pending.cancel.signal.aborted)return;
        active=undefined;
        try{current.postMessage({kind:'decision',id:pending.id,approved});}catch{}
      });
    });
    current.onDisconnect.addListener(()=>{
      void chrome.runtime.lastError;
      if(current!==port)return;
      delete document.documentElement.dataset.panelApprovalReady;
      port=undefined;active?.cancel.abort();active=undefined;
      if(!stopped)retry=setTimeout(connect,800);
    });
    void chrome.windows.getCurrent().then(window=>{
      if(!stopped&&port===current)current.postMessage({kind:'register',windowId:window.id});
    }).catch(()=>current.disconnect());
  };
  // A sidepanel.html opened as an ordinary tab is not an approval presenter.
  void chrome.runtime.getContexts({documentUrls:[location.href]}).then(contexts=>{
    if(!stopped&&contexts.length===1&&contexts[0]?.contextType==='SIDE_PANEL')connect();
  }).catch(()=>{});
  window.addEventListener('pagehide',()=>{
    stopped=true;clearTimeout(retry);active?.cancel.abort();port?.disconnect();
  },{once:true});
}
