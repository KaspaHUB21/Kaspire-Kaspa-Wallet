import {isSidePanelDocument} from '../shared/walletPage';
export interface PanelApproval {
  id:string; origin:string; title:string; description:string; details:string[];
  rawJson?:unknown; recoveryCode?:string; unlockOnly?:boolean; locked?:boolean;
}
type Decision=(approved:boolean)=>Promise<void>|void;
type Request={view:PanelApproval;decide:Decision};
type Panel={port:chrome.runtime.Port;documentId:string;windowId:number;queue:Request[];active?:Request};

/** Presentation only: the existing approval/session/signing checks decide validity. */
export class SidePanelApprovals {
  private panels=new Map<string,Panel>();
  private windows=new Map<string,Map<symbol,number|undefined>>();
  constructor(private root:string,private contexts:(filter:chrome.runtime.ContextFilter)=>Promise<chrome.runtime.ExtensionContext[]>,private windowExists:(id:number)=>Promise<boolean>=async()=>true){}

  async inRequestWindow<T>(origin:string,windowId:number|undefined,operation:()=>Promise<T>):Promise<T> {
    let requests=this.windows.get(origin);
    if(!requests){requests=new Map();this.windows.set(origin,requests);}
    const token=Symbol();requests.set(token,windowId);
    try{return await operation();}finally{requests.delete(token);if(!requests.size)this.windows.delete(origin);}
  }

  async connect(port:chrome.runtime.Port,reportedWindowId?:number) {
    if(port.name!=='wallet-sidepanel-approvals'||!isSidePanelDocument(port.sender?.url,this.root)||!Number.isSafeInteger(reportedWindowId)||reportedWindowId!<0)return false;
    let disconnected=false;
    port.onDisconnect.addListener(()=>{disconnected=true;});
    const url=port.sender!.url!,senderDocumentId=port.sender!.documentId;
    let contexts:chrome.runtime.ExtensionContext[];
    try{contexts=await this.contexts({...(senderDocumentId?{documentIds:[senderDocumentId]}:{}),documentUrls:[url]});}
    catch{return false;}
    const context=contexts.length===1?contexts[0]:undefined;
    if(disconnected||!context||context.contextType!=='SIDE_PANEL'||!context.documentId||context.documentUrl!==url||
      (senderDocumentId&&context.documentId!==senderDocumentId)||
      (context.windowId>=0&&context.windowId!==reportedWindowId))return false;
    if(!await this.windowExists(reportedWindowId!)||disconnected)return false;
    const documentId=context.documentId;
    const old=this.panels.get(documentId);
    if(old)this.detach(old);
    const panel:Panel={port,documentId,windowId:reportedWindowId!,queue:[]};
    this.panels.set(documentId,panel);
    port.onDisconnect.addListener(()=>this.detach(panel));
    port.onMessage.addListener(message=>{
      if(this.panels.get(documentId)!==panel||message?.kind!=='decision'||!panel.active||message.id!==panel.active.view.id)return;
      const request=panel.active;panel.active=undefined;
      void Promise.resolve(request.decide(message.approved===true)).catch(()=>{}).finally(()=>this.advance(panel));
    });
    try{port.postMessage({kind:'ready'});}catch{this.detach(panel);return false;}
    return true;
  }

  present(view:PanelApproval,decide:Decision) {
    const windows=[...new Set(this.windows.get(view.origin)?.values()??[])];
    // Never send a request to another browser window or guess between callers.
    if(windows.length!==1||windows[0]===undefined)return false;
    const panel=[...this.panels.values()].find(p=>p.windowId===windows[0]);
    if(!panel)return false;
    panel.queue.push({view,decide});this.advance(panel);
    return true;
  }

  cancel(id:string) {
    for(const panel of this.panels.values()) {
      panel.queue=panel.queue.filter(r=>r.view.id!==id);
      if(panel.active?.view.id!==id)continue;
      panel.active=undefined;
      try{panel.port.postMessage({kind:'cancel',id});}catch{this.detach(panel);continue;}
      this.advance(panel);
    }
  }

  private advance(panel:Panel) {
    if(this.panels.get(panel.documentId)!==panel||panel.active)return;
    const request=panel.queue.shift();if(!request)return;
    panel.active=request;
    try{panel.port.postMessage({kind:'approval',view:request.view});}catch{this.detach(panel);}
  }

  private detach(panel:Panel) {
    if(this.panels.get(panel.documentId)===panel)this.panels.delete(panel.documentId);
    const requests=[...(panel.active?[panel.active]:[]),...panel.queue];
    panel.active=undefined;panel.queue=[];
    for(const request of requests)void Promise.resolve(request.decide(false)).catch(()=>{});
  }
}
