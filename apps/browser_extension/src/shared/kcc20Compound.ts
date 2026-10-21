// Select a bounded, deterministic next step. A compound is a self-transfer of
// the complete input quantity; it must never make a partial recipient payment.
export function kcc20TransactionCount(requiredCells: number, inputLimit = 3) {
  if(!Number.isSafeInteger(requiredCells)||requiredCells<1||!Number.isSafeInteger(inputLimit)||inputLimit<2)
    throw Error('Invalid KCC20 transaction plan.');
  return Math.max(1,Math.ceil((requiredCells-1)/(inputLimit-1)));
}
export function planKcc20Step<T extends { transactionId: string; index: number; tokenAmount: number }>(cells: T[], amount: number, limit: number) {
  if (!Number.isSafeInteger(amount) || amount <= 0 || !Number.isInteger(limit) || limit < 2)
    throw new Error('Invalid KCC20 compound parameters.');
  const seen = new Set<string>();
  const sorted = [...cells];
  for (const cell of sorted) {
    const key = `${cell.transactionId}:${cell.index}`;
    if (!Number.isSafeInteger(cell.tokenAmount) || cell.tokenAmount <= 0 || seen.has(key)) throw new Error('Invalid or duplicate KCC20 cell.');
    seen.add(key);
  }
  sorted.sort((a,b)=>b.tokenAmount-a.tokenAmount||a.transactionId.localeCompare(b.transactionId)||a.index-b.index);
  let available=0;
  for(const cell of sorted){available+=cell.tokenAmount;if(!Number.isSafeInteger(available))throw new Error('KCC20 amount exceeds safe range.');}
  if(available<amount)throw new Error('Insufficient spendable KCC20 token balance.');
  const selected:T[]=[];let total=0;
  for(const cell of sorted.slice(0,limit)){selected.push(cell);total+=cell.tokenAmount;if(total>=amount)break;}
  let covered=0,requiredCells=0;
  for(const cell of sorted){covered+=cell.tokenAmount;requiredCells++;if(covered>=amount)break;}
  return {cells:selected,amount:total<amount?total:amount,compound:total<amount,requiredCells,transactionCount:kcc20TransactionCount(requiredCells,limit)};
}
