// Narrow mount behind the existing /dex-test-v1/ gateway. No nginx changes required.
import http from 'node:http';
const paths=new Set(['/health','/tokens','/quote','/plan','/apk','/utxos','/prepared','/rocket-cells']);
export function proxyKasseal(req,res) {
  const url=new URL(req.url,'http://localhost');
  const mainnet=url.pathname.startsWith('/kasseal-mainnet/');
  const path=url.pathname.slice((mainnet?'/kasseal-mainnet':'/kasseal').length);
  if(!paths.has(path)||!['GET','HEAD','POST'].includes(req.method)){
    res.writeHead(404);res.end(JSON.stringify({error:'Not found'}));return;
  }
  const upstream=http.request({hostname:'127.0.0.1',port:mainnet?8175:8173,path:path+url.search,method:req.method,
    headers:{'content-type':'application/json'},timeout:60000},answer=>{
    res.statusCode=answer.statusCode;
    for(const header of ['content-type','content-length','content-disposition','cache-control'])if(answer.headers[header])res.setHeader(header,answer.headers[header]);
    answer.pipe(res);
  });
  upstream.on('timeout',()=>upstream.destroy());
  upstream.on('error',()=>{if(!res.headersSent)res.writeHead(503);res.end(JSON.stringify({error:'Kasseal test service is temporarily unavailable.'}));});
  req.on('aborted',()=>upstream.destroy());req.pipe(upstream);
}
