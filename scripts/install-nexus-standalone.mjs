// One-time, non-destructive migration. Never log credentials or write them into
// repository files. Runtime uses only the new Kaspire environment/database.
import {readFileSync,writeFileSync,existsSync,chmodSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
const target='/etc/kaspire-nexus-test.env';
if(existsSync(target))throw Error('Standalone configuration exists; refusing to overwrite it.');
const source=readFileSync('/etc/kasnftnexus.env','utf8');
const config=Object.fromEntries(source.split('\n').filter(l=>/^[A-Z_]+=/.test(l)).map(l=>{const i=l.indexOf('=');return [l.slice(0,i),l.slice(i+1).replace(/^['"]|['"]$/g,'')];}));
const oldDb=new URL(config.DATABASE_URL).pathname.slice(1);
if(!/^[a-zA-Z0-9_]+$/.test(oldDb))throw Error('Invalid migration database name.');
const sql=(input)=>execFileSync('runuser',['-u','postgres','--','psql','-X','-v','ON_ERROR_STOP=1','-tA'],{input,stdio:['pipe','pipe','pipe']}).toString();
if(sql("SELECT datname FROM pg_database WHERE datname='kaspire_nexus_test';").trim())throw Error('Target database exists; refusing to overwrite it.');
const password=randomBytes(32).toString('hex'),secret=randomBytes(48).toString('hex');
sql(`CREATE ROLE kaspire_nexus_test LOGIN PASSWORD '${password}';\nCREATE DATABASE kaspire_nexus_test OWNER kaspire_nexus_test;`);
const dump=execFileSync('runuser',['-u','postgres','--','pg_dump','--format=custom','--no-owner','--no-acl',oldDb],{maxBuffer:512*1024*1024,stdio:['ignore','pipe','pipe']});
execFileSync('runuser',['-u','postgres','--','pg_restore','--exit-on-error','--no-owner','--no-acl','--role=kaspire_nexus_test','--dbname=kaspire_nexus_test'],{input:dump,maxBuffer:512*1024*1024,stdio:['pipe','pipe','pipe']});
const lines=['NODE_ENV=production','APP_URL=https://kaspire.kaslab.space',`DATABASE_URL=postgresql://kaspire_nexus_test:${password}@127.0.0.1:5432/kaspire_nexus_test?schema=public`,`SESSION_SECRET=${secret}`];
for(const name of ['KRC721_PRIVATE_BASE_URL','KRC721_PRIVATE_API_KEY'])if(config[name])lines.push(`${name}=${config[name]}`);
writeFileSync(target,lines.join('\n')+'\n',{mode:0o600,flag:'wx'});chmodSync(target,0o600);
console.log('Independent Kaspire database snapshot and private configuration created; original database unchanged.');
