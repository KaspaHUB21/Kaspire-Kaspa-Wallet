declare module 'kaspire-trestly-wasm'{
 export default function init(input:{module_or_path:BufferSource|WebAssembly.Module}):Promise<unknown>;
 export function describeTrestly(request:string):string;
 export function prepareTrestly(request:string):string;
 export function signTrestly(secret:Uint8Array,request:string,hash:string):string;
}
