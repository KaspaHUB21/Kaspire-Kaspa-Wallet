import http from 'node:http';
import {catalogue,quote,plan} from './kron.mjs';
import {proxyKasseal} from '../kasseal-test/proxy.mjs';
let active=0;
const limits=new Map();
const server=http.createServer(async(req,res)=>{
  res.setHeader('content-type','application/json');res.setHeader('cache-control','no-store');
  const send=(status,data)=>{res.writeHead(status);res.end(JSON.stringify(data));};
  const ip=req.socket.remoteAddress,now=Date.now(),rate=limits.get(ip)??{time:now,count:0};
  if(now-rate.time>60000){rate.time=now;rate.count=0;}limits.set(ip,rate);
  if(++rate.count>90)return send(429,{error:'Too many requests; wait a minute.'});
  if(limits.size>10000)for(const[key,value]of limits)if(now-value.time>60000)limits.delete(key);
  try{
    const path=new URL(req.url,'http://localhost').pathname;
    if(path.startsWith('/kasseal/')||path.startsWith('/kasseal-mainnet/'))return proxyKasseal(req,res);
    if(req.method==='GET'&&path==='/kron/tokens')return send(200,await catalogue());
    if(req.method!=='POST'||!['/kron/quote','/kron/plan'].includes(path))return send(404,{error:'Not found'});
    let text='',length=0;
    for await(const part of req){length+=part.length;if(length>4096)return send(413,{error:'Request too large'});text+=part;}
    const body=JSON.parse(text);
    if(!/^[a-f0-9]{64}$/.test(body.tokenId)||!['buy','sell'].includes(body.side)||!/^[1-9][0-9]{0,18}$/.test(body.rawAmount))return send(400,{error:'Invalid trade amount or token ID'});
    if(path==='/kron/quote')return send(200,await quote(body));
    if(typeof body.address!=='string'||body.address.length>120||!/^kaspa:[a-z0-9]+$/.test(body.address)||!/^[0-9]{1,19}$/.test(body.minimumReceive))return send(400,{error:'Invalid wallet or slippage limit'});
    if(active>=3)return send(503,{error:'DEX is busy. Retry shortly.'});
    active++;try{return send(200,await plan(body));}finally{active--;}
  }catch(error){send(400,{error:error.message??'Trade could not be prepared'});}
});
server.requestTimeout=60000;
server.listen(Number(process.env.PORT??8172),'127.0.0.1',()=>console.log('Kaspire KRON test planner listening on loopback'));
