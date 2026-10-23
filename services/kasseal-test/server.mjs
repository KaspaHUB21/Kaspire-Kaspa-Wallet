import http from 'node:http';
import {createReadStream,statSync} from 'node:fs';
import {catalogue,quote,plan,preparationReady} from './planner.mjs';
import {utxos} from './node.mjs';
import {NETWORK} from './network.mjs';
import {rocketCells} from './rocket-cells.mjs';
let active=0;
const server=http.createServer(async(req,res)=>{
  res.setHeader('content-type','application/json');res.setHeader('cache-control','no-store');
  const send=(status,data)=>{res.writeHead(status);res.end(JSON.stringify(data));};
  try{
    const url=new URL(req.url,'http://localhost');
    if(['GET','HEAD'].includes(req.method)&&url.pathname==='/apk'){
      if(NETWORK!=='testnet-10')return send(404,{error:'Not found'});
      const path='/srv/kaspire/source/apps/mobile_flutter/artifacts/internal/kasseal-tn10-build202/Kaspire-Android-Kasseal-TN10-build202.apk';
      let stat;try{stat=statSync(path);}catch{return send(404,{error:'Test APK has not been built yet.'});}
      res.writeHead(200,{'content-type':'application/vnd.android.package-archive','content-length':stat.size,
        'content-disposition':'attachment; filename="Kaspire-Android-Kasseal-TN10-build202.apk"','x-content-type-options':'nosniff'});
      if(req.method==='HEAD'){res.end();return;}
      const stream=createReadStream(path);res.on('close',()=>stream.destroy());stream.on('error',()=>res.destroy());stream.pipe(res);return;
    }
    if(req.method==='GET'&&url.pathname==='/tokens')return send(200,await catalogue(url.searchParams.get('cursor')??'',url.searchParams.get('search')??''));
    if(req.method==='GET'&&url.pathname==='/health')return send(200,{network:NETWORK,unsignedOnly:true,sdk:'0.1.1'});
    if(req.method==='GET'&&url.pathname==='/rocket-cells'){
      if(active>=3)return send(503,{error:'Cell verification is busy. Please retry shortly.'});
      active++;try{return send(200,await rocketCells(url.searchParams.get('address'),url.searchParams.get('tokenId'),url.searchParams.get('amount'),url.searchParams.get('fullPlan')??'1'));}finally{active--;}
    }
    if(req.method==='GET'&&url.pathname==='/prepared'){
      if(active>=3)return send(503,{error:'Kasseal preparation lookup is busy. Please retry shortly.'});
      active++;try{return send(200,await preparationReady(url.searchParams.get('address'),url.searchParams.get('tokenId'),url.searchParams.get('transactionId')));}finally{active--;}
    }
    if(req.method==='GET'&&url.pathname==='/utxos'){
      if(active>=3)return send(503,{error:'TN10 verification is busy. Please retry shortly.'});
      active++;try{return send(200,await utxos(url.searchParams.get('address')));}finally{active--;}
    }
    if(req.method!=='POST'||!['/quote','/plan'].includes(url.pathname))return send(404,{error:'Not found'});
    let text='',size=0;for await(const chunk of req){size+=chunk.length;if(size>4096)return send(413,{error:'Request too large'});text+=chunk;}
    const body=JSON.parse(text),allowed=['network','address','tokenId','side','rawAmount','minimumReceive','maxSpendSompi','allowPreparation'];
    if(Object.keys(body).some(k=>!allowed.includes(k)))return send(400,{error:'Only public unsigned trade parameters are accepted.'});
    if(active>=3)return send(503,{error:'Kasseal planner is busy. Please retry shortly.'});
    active++;try{return send(200,await(url.pathname==='/quote'?quote(body):plan(body)));}finally{active--;}
  }catch(error){
    let message=error.message??'Trade could not be prepared';
    if(error.errorCode==='NEEDS_SPLIT') message='This partial sale needs a token-cell split first. Choose an existing exact cell amount or prepare the split in Kasseal. No transaction was signed.';
    if(error.errorCode==='NEEDS_CONSOLIDATION') message='This sale needs a token-cell merge first. Sell an existing cell separately or prepare the merge in Kasseal. No transaction was signed.';
    send(400,{error:message,code:error.errorCode??error.name});
  }
});
server.requestTimeout=60000;server.headersTimeout=15000;
server.listen(Number(process.env.PORT??8173),'127.0.0.1',()=>console.log('Kasseal unsigned TN10 planner ready'));
