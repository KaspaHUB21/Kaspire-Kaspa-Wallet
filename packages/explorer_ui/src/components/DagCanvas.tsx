import {useEffect,useMemo,useRef} from 'react';
import {layoutDag,hitDag,type DagBlock,type DagNode,type DagSnapshot} from '../dag';
type Props={snapshot:DagSnapshot|null;zoom:number;follow:boolean;selected:string|null;onSelect:(b:DagBlock)=>void;onPan:()=>void;onZoom:(n:number)=>void};
export function DagCanvas(props:Props){
 const canvas=useRef<HTMLCanvasElement>(null),cache=useRef({epoch:'',nodes:new Map<string,DagNode>()});
 const layout=useMemo(()=>{const old=cache.current.epoch===props.snapshot?.epoch?cache.current.nodes:new Map();const model=layoutDag(props.snapshot?.blocks??[],old);cache.current={epoch:props.snapshot?.epoch??'',nodes:new Map(model.nodes.map(n=>[n.hash,n]))};return model;},[props.snapshot?.blocks,props.snapshot?.epoch]);
 const latest=useRef({props,layout}),redraw=useRef<()=>void>(()=>{});latest.current={props,layout};
 useEffect(()=>{redraw.current();},[props.zoom,props.follow,props.selected,props.snapshot,layout]);
 useEffect(()=>{
  const c=canvas.current!,ctx=c.getContext('2d')!;let frame=0,w=0,h=0,alive=true;
  const camera={x:NaN,y:NaN},pointers=new Map<number,{x:number;y:number}>();let last:{x:number;y:number}|null=null,start:{x:number;y:number}|null=null,dragged=false,pinch=0;
  let colors={primary:'#7ef4e7',text:'#f1f8fb',bg:'#031d29',line:'#82949c',nodeText:'#031d29'};
  const readColors=()=>{const s=getComputedStyle(document.documentElement),rgb=(key:string,fallback:string)=>s.getPropertyValue(key).trim()?`rgb(${s.getPropertyValue(key).trim().split(/\s+/).join(',')})`:fallback;const glacier=document.documentElement.dataset.kaspireTheme==='glacier';colors={primary:glacier?'#08666b':rgb('--kaspa-primary','#7ef4e7'),text:rgb('--kaspa-text','#f1f8fb'),bg:rgb('--kaspa-background','#031d29'),line:rgb('--kaspa-muted','#82949c'),nodeText:glacier?'#ffffff':rgb('--kaspa-background','#031d29')};};
  const schedule=()=>{if(alive&&!frame&&document.visibilityState!=='hidden')frame=requestAnimationFrame(draw);};
  const draw=()=>{
   frame=0;if(!alive)return;const {props:p,layout:m}=latest.current,dpr=Math.min(2,window.devicePixelRatio||1),r=c.getBoundingClientRect();w=r.width;h=r.height;if(!w||!h)return;
   if(c.width!==Math.round(w*dpr)||c.height!==Math.round(h*dpr)){c.width=Math.round(w*dpr);c.height=Math.round(h*dpr);}
   const target={x:w-m.width*p.zoom-12,y:(h-24-m.height*p.zoom)/2};let moving=false;
   if(!Number.isFinite(camera.x)){camera.x=target.x;camera.y=target.y;}
   if(p.follow){const direct=matchMedia('(prefers-reduced-motion: reduce)').matches;for(const axis of ['x','y'] as const){const d=target[axis]-camera[axis];if(Math.abs(d)>.3){camera[axis]+=direct?d:d*.22;moving=!direct;}else camera[axis]=target[axis];}}
   ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);ctx.save();ctx.beginPath();ctx.rect(0,0,w,h-22);ctx.clip();ctx.translate(camera.x,camera.y);ctx.scale(p.zoom,p.zoom);
   const visible=(n:DagNode)=>n.x*p.zoom+camera.x>-40&&n.x*p.zoom+camera.x<w+40&&n.y*p.zoom+camera.y>-40&&n.y*p.zoom+camera.y<h+40;
   for(const selected of [false,true]){ctx.beginPath();for(const e of m.edges){if(e.selected!==selected||!visible(e.from)&&!visible(e.to))continue;ctx.moveTo(e.from.x,e.from.y);ctx.lineTo(e.to.x,e.to.y);}ctx.strokeStyle=selected?colors.primary:colors.line;ctx.globalAlpha=selected?.7:.22;ctx.lineWidth=(selected?1.4:.7)/p.zoom;ctx.stroke();}
   const newest=m.nodes.reduce((a,n)=>Math.max(a,n.observedAt),0);
   for(const n of m.nodes){if(!visible(n))continue;const active=n.hash===p.selected;ctx.globalAlpha=active||n.observedAt===newest?1:.8;ctx.fillStyle=colors.primary;ctx.beginPath();if(ctx.roundRect)ctx.roundRect(n.x-19,n.y-14,38,28,5);else ctx.rect(n.x-19,n.y-14,38,28);ctx.fill();if(active){ctx.strokeStyle=colors.text;ctx.lineWidth=2.5/p.zoom;ctx.stroke();}if(p.zoom>=.4){ctx.globalAlpha=1;ctx.fillStyle=colors.nodeText;ctx.font=`600 ${Math.min(19,11/p.zoom)}px ui-monospace,monospace`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(n.hash.slice(0,p.zoom<.8?2:4).toUpperCase(),n.x,n.y);}}
   ctx.restore();ctx.globalAlpha=1;ctx.fillStyle=colors.line;ctx.font='10px system-ui';ctx.textBaseline='bottom';ctx.textAlign='center';let labelX=-100;const labelled=new Set<number>();for(const n of m.nodes){const x=n.x*p.zoom+camera.x;if(x<35||x>w-35||x-labelX<85||labelled.has(n.column))continue;ctx.fillText(BigInt(n.daaScore).toLocaleString('en-US'),x,h-2);labelled.add(n.column);labelX=x;}
   if(moving)schedule();
  };
  const position=(e:PointerEvent)=>{const r=c.getBoundingClientRect();return{x:e.clientX-r.left,y:e.clientY-r.top};};
  const down=(e:PointerEvent)=>{e.preventDefault();const pos=position(e);pointers.set(e.pointerId,pos);c.setPointerCapture(e.pointerId);last=pos;start=pos;dragged=false;if(pointers.size===2){const [a,b]=[...pointers.values()];pinch=Math.hypot(a.x-b.x,a.y-b.y);dragged=true;}};
  const move=(e:PointerEvent)=>{const pos=position(e);if(!pointers.has(e.pointerId)){const p=latest.current.props,n=hitDag(latest.current.layout.nodes,(pos.x-camera.x)/p.zoom,(pos.y-camera.y)/p.zoom,p.zoom);c.style.cursor=n?'pointer':'grab';c.title=n?`${n.hash}\nDAA ${n.daaScore} · ${n.parents.length} parents`:'';return;}e.preventDefault();pointers.set(e.pointerId,pos);const p=latest.current.props;if(pointers.size===2){const[a,b]=[...pointers.values()],d=Math.hypot(a.x-b.x,a.y-b.y);if(pinch>0)p.onZoom(Math.max(.2,Math.min(2,p.zoom*d/pinch)));pinch=d;dragged=true;}else if(last){if(start&&Math.hypot(pos.x-start.x,pos.y-start.y)>5)dragged=true;if(dragged){p.onPan();camera.x+=pos.x-last.x;camera.y+=pos.y-last.y;schedule();}}last=pos;};
  const up=(e:PointerEvent)=>{const p=latest.current.props,pos=position(e);if(!dragged&&pointers.size===1){const b=hitDag(latest.current.layout.nodes,(pos.x-camera.x)/p.zoom,(pos.y-camera.y)/p.zoom,p.zoom);if(b)p.onSelect(b);}pointers.delete(e.pointerId);if(c.hasPointerCapture(e.pointerId))c.releasePointerCapture(e.pointerId);last=null;pinch=0;};
  const cancel=(e:PointerEvent)=>{pointers.delete(e.pointerId);last=null;dragged=true;};
  const wheel=(e:WheelEvent)=>{e.preventDefault();const p=latest.current.props;p.onZoom(Math.max(.2,Math.min(2,p.zoom*(e.deltaY>0?.9:1.1))));};
  for(const[type,fn]of [['pointerdown',down],['pointermove',move],['pointerup',up],['pointercancel',cancel]] as const)c.addEventListener(type,fn);
  c.addEventListener('wheel',wheel,{passive:false});const resize=new ResizeObserver(schedule);resize.observe(c);const theme=new MutationObserver(()=>{readColors();schedule();});theme.observe(document.documentElement,{attributes:true,attributeFilter:['style','data-kaspire-theme']});document.addEventListener('visibilitychange',schedule);readColors();redraw.current=schedule;schedule();
  return()=>{alive=false;cancelAnimationFrame(frame);resize.disconnect();theme.disconnect();document.removeEventListener('visibilitychange',schedule);for(const[type,fn]of [['pointerdown',down],['pointermove',move],['pointerup',up],['pointercancel',cancel]] as const)c.removeEventListener(type,fn);c.removeEventListener('wheel',wheel);redraw.current=()=>{};};
 },[]);
 return <canvas ref={canvas} data-dag-canvas data-node-count={layout.nodes.length} data-edge-count={layout.edges.length} className="block h-[380px] w-full rounded-md sm:h-[480px]" style={{touchAction:'none'}} role="img" aria-label="Observed Kaspa blocks and their real parent links. Select a block using the recent-block cards below."/>;
}
