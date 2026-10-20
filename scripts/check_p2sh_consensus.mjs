// Synthetic/offline only. The checker has no Kaspire signer or network client.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rev='01b532e8b553523216471682649693af92f0fd16';
const metadata=JSON.parse(execFileSync('cargo',['metadata','--locked','--format-version','1'],{cwd:root,maxBuffer:24*1024*1024}));
const pkg=metadata.packages.find(p=>p.name==='kaspa-consensus-core'&&p.source?.endsWith('#'+rev));
if(!pkg)throw Error('Pinned v2.1.0 consensus source is missing');
const source=resolve(dirname(pkg.manifest_path),'../..');
const env={...process.env,RUSTY_KASPA_SOURCE:source,CARGO_TARGET_DIR:resolve(root,'target')};
const args=['run','--locked','--quiet','--manifest-path',resolve(root,'tools/p2sh-consensus-check/Cargo.toml')];
const input=process.argv[2]
  ? readFileSync(process.argv[2]==='-' ? 0 : resolve(process.argv[2]))
  : execFileSync('cargo',['run','--locked','--quiet','-p','kaspa_secure_core','--example','hidden_browser_fixture'],{cwd:root,maxBuffer:8*1024*1024});
const output=execFileSync('cargo',args,{cwd:root,env,input,maxBuffer:2*1024*1024,stdio:['pipe','pipe','inherit']});
process.stdout.write(output);
