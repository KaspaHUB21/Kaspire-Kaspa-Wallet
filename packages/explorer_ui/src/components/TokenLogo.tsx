import { useState } from "react";
import {publicImage} from '../images';

interface TokenLogoProps {
  src?: string;
  fallbackSrcs?: (string|undefined)[];
  symbol: string;
  size?: "sm" | "md" | "lg";
}

const sizeClass = {
  sm: "h-8 w-8 text-xs",
  md: "h-11 w-11 text-sm",
  lg: "h-14 w-14 text-base"
};

export function TokenLogo({ src, fallbackSrcs=[], symbol, size = "md" }: TokenLogoProps) {
  const sources=[...new Set([src,...fallbackSrcs].map(publicImage).filter((s):s is string=>!!s))];
  const key=sources.join('|');
  const [failed,setFailed]=useState({key:'',index:0});
  const index=failed.key===key?failed.index:0,current=sources[index];
  const showImage=!!current;

  return (
    <div data-token-logo={current} data-logo-candidates={sources.join("|")} className={["flex shrink-0 items-center justify-center overflow-hidden rounded-md border border-kaspa-border bg-kaspa-background", sizeClass[size]].join(" ")}>
      {showImage ? <img key={current} src={current} alt="" decoding="async" className="h-full w-full object-cover" onError={() => setFailed({key,index:index+1})} /> : null}
      {!showImage ? <span className="flex h-full w-full items-center justify-center font-bold text-kaspa-primary">{symbol.slice(0, 4)}</span> : null}
    </div>
  );
}

