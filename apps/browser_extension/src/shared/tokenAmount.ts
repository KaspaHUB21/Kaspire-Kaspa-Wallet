export function formatRawTokenAmount(raw: string, decimals: number): string {
  if (!/^[0-9]+$/.test(raw) || !Number.isInteger(decimals) || decimals < 0 || decimals > 18) {
    throw new Error("Invalid raw token amount.");
  }
  if (decimals === 0) return BigInt(raw).toString();
  const digits = BigInt(raw).toString().padStart(decimals + 1, "0");
  const whole = digits.slice(0, -decimals);
  const fraction = digits.slice(-decimals).replace(/0+$/g, "");
  return fraction ? `${whole}.${fraction}` : whole;
}

/** Display only. Never feed grouped strings back into a signing request. */
export function formatTokenDisplay(raw:string,decimals:number):string{
  const n=BigInt(raw),[whole,fraction]=formatRawTokenAmount(String(n<0n?-n:n),decimals).split('.');
  return (n<0n?'-':'')+whole!.replace(/\B(?=(\d{3})+(?!\d))/g,',')+(fraction?'.'+fraction:'');
}
