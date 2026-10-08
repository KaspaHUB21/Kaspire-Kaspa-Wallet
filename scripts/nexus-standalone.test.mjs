import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {join} from 'node:path';
test('runtime is owned by Kaspire and cannot read the former website',()=>{
 const service=readFileSync(new URL('../ops/kaspire-nexus-test.service',import.meta.url),'utf8');
 assert.match(service,/User=kaspire-nexus/);
 assert.match(service,/EnvironmentFile=\/etc\/kaspire-nexus-test.env/);
 assert.match(service,/InaccessiblePaths=-\/srv\/kasnftnexus -\/etc\/kasnftnexus.env/);
 assert.ok(!service.includes('After=network-online.target kasnftnexus.service'));
 const server=readFileSync(new URL('./nexus-server.ts',import.meta.url),'utf8');
 assert.ok(!server.includes('kaspanftnexus.com'));
 assert.ok(!server.includes('/srv/kasnftnexus'));
 const root=new URL('../services/nft-nexus/src/',import.meta.url);
 function scan(dir){for(const e of readdirSync(dir,{withFileTypes:true})){const p=join(dir,e.name);if(e.isDirectory())scan(p);else if(e.name.endsWith('.ts')){const text=readFileSync(p,'utf8');assert.ok(!/kaspanftnexus\.com|\/srv\/kasnftnexus|next\//.test(text),p);}}}
 scan(root.pathname);
});
