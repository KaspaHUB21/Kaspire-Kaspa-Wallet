// Display only; never supplies executable programs or transaction authority.
export function verifiedKascovDeclaration(covenantId:string,source:any):any|null {
  const proof=source?.kcc23;
  if(source?.covenant_id!==covenantId||proof?.binding!=='verified'||typeof proof.declaration!=='string'||proof.declaration.length>16384)return null;
  try{
    const data=JSON.parse(proof.declaration),ticker=String(data?.ticker??data?.symbol??'').toUpperCase();
    if(!/^[A-Z0-9_.-]{1,32}$/.test(ticker)||!Number.isInteger(data?.decimals)||data.decimals<0||data.decimals>18)return null;
    return {...data,ticker};
  }catch{return null;}
}
