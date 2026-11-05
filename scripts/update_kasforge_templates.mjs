// Extract public MIT-licensed template DATA only. Never import/run the SDK and
// never read a confidential partner kit into the public source tree.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const archive=process.argv[2];
if(!archive)throw Error('Pass the public SDK 0.5.1 npm tarball.');
const integrity='ASJrrK9wmGEYhuQg4GpBvLmV83MninB/Dz+d+RMyCPsaY/Nzc5WEo7nuMEVMIIFClegzgb0QTKMYTRz4UJf9Nw==';
if(crypto.createHash('sha512').update(fs.readFileSync(archive)).digest('base64')!==integrity)throw Error('Public SDK integrity differs.');
const source=execFileSync('tar',['-xOzf',archive,'package/src/order-templates.js'],{encoding:'utf8',maxBuffer:200000});
const data=JSON.parse(source.slice(source.indexOf('export const ORDER_TEMPLATES = ')+30).trim().replace(/;$/,''));
const keys=['ForgeBuyOrder','ForgeBuyOrder_v4','ForgeBuyOrder_v33','ForgeSellOrder','ForgeSellOrder_v3','ForgeSellOrder_v1','KCC20'];
if(Object.keys(data).sort().join()!==keys.sort().join())throw Error('Unexpected public template set.');
const dest=path.resolve(import.meta.dirname,'../crates/kaspa_secure_core/src/kasforge_templates.json');
const previous=JSON.parse(fs.readFileSync(dest,'utf8'));
if(JSON.stringify(previous.KCC20)!==JSON.stringify(data.KCC20))throw Error('Token template changed; independent integration required.');
fs.writeFileSync(dest,JSON.stringify(data,null,2)+'\n');
console.log('Pinned public SDK 0.5.1 templates; token template unchanged.');
