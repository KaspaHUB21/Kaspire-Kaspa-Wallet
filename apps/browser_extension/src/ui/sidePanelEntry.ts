// Each browsing context gets an independent public identifier. A real document
// navigation makes Chrome report this exact URL to both runtime APIs and ports.
const key='kaspire-sidepanel-view';
const valid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
let view=sessionStorage.getItem(key);
if(!view||!valid.test(view)){view=crypto.randomUUID();sessionStorage.setItem(key,view);}
const url=new URL(location.href);
if(url.search!==`?view=${view}`||url.hash)location.replace(`${chrome.runtime.getURL('sidepanel.html')}?view=${view}`);
else void import('./wallet');
export {};
