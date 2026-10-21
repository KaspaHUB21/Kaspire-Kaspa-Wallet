type DeadlineClock = {now:()=>number;set:(callback:()=>void,ms:number)=>ReturnType<typeof setTimeout>;clear:(timer:ReturnType<typeof setTimeout>)=>void};
/** Progress renews idle time, but can never extend the overall hard deadline. */
export function operationDeadline(expire:()=>void,idleMs:number,maxMs:number,
  clock:DeadlineClock={now:()=>Date.now(),set:(f,ms)=>setTimeout(f,ms),clear:t=>clearTimeout(t)}) {
  const started=clock.now();let timer:ReturnType<typeof setTimeout>|undefined;let closed=false;
  const close=()=>{closed=true;if(timer!==undefined)clock.clear(timer);};
  const progress=()=>{
    if(closed)return;
    if(timer!==undefined)clock.clear(timer);
    const remaining=maxMs-(clock.now()-started);
    const timeout=()=>{close();expire();};
    if(remaining<=0)timeout();else timer=clock.set(timeout,Math.min(idleMs,remaining));
  };
  progress();return {progress,close};
}
