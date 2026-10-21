// Recovery never prepares or signs. It can only replay these exact approved bytes.
export type Kcc20PaymentPlan = {
  sender:string; operation:any; reviewHash:string; totalFeeSompi:number;
  transactions:{transactionId:string;signedTxJson:string;feeSompi:number;operation:any}[];
  nextStep:number; createdAt:number;
};
export async function runKcc20PaymentPlan(plan:Kcc20PaymentPlan, address:string, io:{
  save:(plan:Kcc20PaymentPlan)=>Promise<void>;
  accepted:(id:string)=>Promise<boolean>;
  broadcast:(bytes:string,id:string)=>Promise<unknown>;
  record:(tx:Kcc20PaymentPlan['transactions'][number])=>Promise<void>;
  check:()=>Promise<void>;
  progress?:(stage:string)=>void;
  pause?:()=>Promise<void>;
}) {
  if(plan.sender!==address || !/^[0-9a-f]{64}$/.test(plan.reviewHash) ||
    !Number.isInteger(plan.nextStep)||plan.nextStep<0||plan.nextStep>plan.transactions.length||
    !plan.transactions.length||plan.transactions.length>32 ||
    plan.transactions.some(t=>!/^[0-9a-f]{64}$/.test(t.transactionId)||typeof t.signedTxJson!=='string'))
    throw Error('Invalid saved KCC20 plan or different wallet.');
  // Callers also save before entering. This barrier prevents a send if storage fails.
  await io.save(plan);
  for(let i=plan.nextStep;i<plan.transactions.length;i++) {
    await io.check();
    const tx=plan.transactions[i]!;
    io.progress?.(`KCC20 payment: transaction ${i+1} of ${plan.transactions.length}. ${i+1<plan.transactions.length?'Consolidating own cells; recipient not paid yet.':'Sending final recipient payment.'}`);
    let accepted=false;
    try{accepted=await io.accepted(tx.transactionId);}catch{/* Replaying identical bytes is safe. */}
    let broadcastError:unknown;
    if(!accepted) {
      try{await io.broadcast(tx.signedTxJson,tx.transactionId);}catch(e){broadcastError=e;}
      for(let attempt=0;attempt<12&&!accepted;attempt++) {
        try{accepted=await io.accepted(tx.transactionId);}catch{/* Confirmation may lag. */}
        if(!accepted)await (io.pause?.()??new Promise(r=>setTimeout(r,1500)));
      }
    }
    if(!accepted)throw Error(`KCC20 plan saved at transaction ${i+1}/${plan.transactions.length}. Confirmation pending; use Continue KCC20 transfer. No new payment will be created.${broadcastError?' '+String(broadcastError):''}`);
    await io.record(tx);
    // Commit the checkpoint before changing the in-memory cursor.
    await io.save({...plan,nextStep:i+1});
    plan.nextStep=i+1;
  }
  return plan.transactions.at(-1)!;
}
