export function exactTokenAmount(raw:string,decimals:number|null):string {
 if(!/^\d+$/.test(raw)||decimals!==null&&(!Number.isInteger(decimals)||decimals<0||decimals>18))return 'Unavailable';
 if(decimals===null)return raw+' raw units';const n=BigInt(raw),scale=10n**BigInt(decimals),fraction=String(n%scale).padStart(decimals,'0').replace(/0+$/,'');return (n/scale).toLocaleString('en-US')+(fraction?'.'+fraction:'');
}
