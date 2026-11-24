import {execFileSync} from 'node:child_process';
import {mkdir,readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
const dest=process.argv[2]??'generated/trestly';
if(!['generated/trestly','tests/generated/trestly'].includes(dest))throw Error('Invalid pool build destination.');
const target=process.env.CARGO_TARGET_DIR?resolve(process.env.CARGO_TARGET_DIR):resolve('../../target');
await mkdir(dest,{recursive:true});
for(const [name,expected] of Object.entries({pool:'6ecab31a4cffe45ba8e9ae3cf1bb816513b3dd9dd9dc2c6916419dd90b1c114d',kusdt:'0be979f43ca87fb4f9acdf165f1b6e71cffbd892d2fcb137a1151245e1bcd861'})){
 const bytes=await readFile('../../packages/trestly-kaspa/artifacts/'+name+'.json');
 if(createHash('sha256').update(bytes).digest('hex')!==expected)throw Error('Pinned native swap artifact differs: '+name);
}
// Invalidate this crate's ABI/cache, not the user's other platform artifacts.
execFileSync('cargo',['clean','--locked','-p','trestly_web_core','--release','--target','wasm32-unknown-unknown'],{cwd:'../..',stdio:'inherit'});
execFileSync('cargo',['build','--locked','--release','--lib','-p','trestly_web_core','--target','wasm32-unknown-unknown'],{cwd:'../..',stdio:'inherit'});
execFileSync(process.env.WASM_BINDGEN??'/root/.cargo/bin/wasm-bindgen',[resolve(target,'wasm32-unknown-unknown/release/trestly_web_core.wasm'),'--target','web','--out-dir',dest,'--no-typescript'],{stdio:'inherit'});
