import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement>;

function IconBase({ children, ...props }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>
      {children}
    </svg>
  );
}

export function Activity(props: IconProps) {
  return <IconBase {...props}><path d="M22 12h-4l-3 8-6-16-3 8H2" /></IconBase>;
}

export function AlertTriangle(props: IconProps) {
  return <IconBase {...props}><path d="m12 3 10 18H2L12 3Z" /><path d="M12 9v4" /><path d="M12 17h.01" /></IconBase>;
}

export function ArrowLeft(props: IconProps) {
  return <IconBase {...props}><path d="M19 12H5" /><path d="m12 19-7-7 7-7" /></IconBase>;
}

export function ArrowRight(props: IconProps) {
  return <IconBase {...props}><path d="M5 12h14" /><path d="m12 5 7 7-7 7" /></IconBase>;
}

export function BarChart3(props: IconProps) {
  return <IconBase {...props}><path d="M3 3v18h18" /><path d="M8 17V9" /><path d="M13 17V5" /><path d="M18 17v-4" /></IconBase>;
}

export function CheckCircle2(props: IconProps) {
  return <IconBase {...props}><circle cx="12" cy="12" r="10" /><path d="m9 12 2 2 4-5" /></IconBase>;
}

export function Calculator(props: IconProps) {
  return <IconBase {...props}><rect x="4" y="2" width="16" height="20" rx="2" /><path d="M8 6h8" /><path d="M8 10h.01" /><path d="M12 10h.01" /><path d="M16 10h.01" /><path d="M8 14h.01" /><path d="M12 14h.01" /><path d="M16 14h.01" /><path d="M8 18h.01" /><path d="M12 18h.01" /><path d="M16 18h.01" /></IconBase>;
}

export function CircleDashed(props: IconProps) {
  return <IconBase {...props}><path d="M10.1 2.2a10 10 0 0 1 3.8 0" /><path d="M17.6 4.4a10 10 0 0 1 2 3.3" /><path d="M21.8 10.1a10 10 0 0 1 0 3.8" /><path d="M19.6 17.6a10 10 0 0 1-3.3 2" /><path d="M13.9 21.8a10 10 0 0 1-3.8 0" /><path d="M6.4 19.6a10 10 0 0 1-2-3.3" /><path d="M2.2 13.9a10 10 0 0 1 0-3.8" /><path d="M4.4 6.4a10 10 0 0 1 3.3-2" /></IconBase>;
}

export function Circle(props: IconProps) {
  return <IconBase {...props}><circle cx="12" cy="12" r="8" /></IconBase>;
}

export function Crown(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="none" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>
      <defs>
        <linearGradient id="hub21-crown" x1="2" y1="3" x2="22" y2="21" gradientUnits="userSpaceOnUse">
          <stop stopColor="#e7e4dd" />
          <stop offset="0.48" stopColor="#fff1c7" />
          <stop offset="1" stopColor="#c38d21" />
        </linearGradient>
      </defs>
      <path stroke="url(#hub21-crown)" d="m2 4 3 12h14l3-12-6 7-4-7-4 7-6-7Z" />
      <path stroke="url(#hub21-crown)" d="M5 20h14" />
    </svg>
  );
}

export function DatabaseZap(props: IconProps) {
  return <IconBase {...props}><ellipse cx="12" cy="5" rx="8" ry="3" /><path d="M4 5v6c0 1.7 3.6 3 8 3 1.1 0 2.2-.1 3.1-.3" /><path d="M4 11v6c0 1.7 3.6 3 8 3 .8 0 1.6 0 2.3-.1" /><path d="m19 11-3 5h4l-3 5" /></IconBase>;
}

export function Download(props: IconProps) {
  return <IconBase {...props}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="M7 10l5 5 5-5" /><path d="M12 15V3" /></IconBase>;
}

export function Layers3(props: IconProps) {
  return <IconBase {...props}><path d="m12 2 10 5-10 5L2 7l10-5Z" /><path d="m2 17 10 5 10-5" /><path d="m2 12 10 5 10-5" /></IconBase>;
}

export function LayoutGrid(props: IconProps) {
  return <IconBase {...props}><rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" /><rect x="14" y="14" width="7" height="7" /><rect x="3" y="14" width="7" height="7" /></IconBase>;
}

export function List(props: IconProps) {
  return <IconBase {...props}><path d="M8 6h13" /><path d="M8 12h13" /><path d="M8 18h13" /><path d="M3 6h.01" /><path d="M3 12h.01" /><path d="M3 18h.01" /></IconBase>;
}

export function ListFilter(props: IconProps) {
  return <IconBase {...props}><path d="M3 6h18" /><path d="M7 12h10" /><path d="M10 18h4" /></IconBase>;
}

export function Menu(props: IconProps) {
  return <IconBase {...props}><path d="M4 6h16" /><path d="M4 12h16" /><path d="M4 18h16" /></IconBase>;
}

export function Moon(props: IconProps) {
  return <IconBase {...props}><path d="M20.5 14.2A8.5 8.5 0 0 1 9.8 3.5 9 9 0 1 0 20.5 14.2Z" /></IconBase>;
}

export function PieChart(props: IconProps) {
  return <IconBase {...props}><path d="M21 12c0 5-4 9-9 9s-9-4-9-9 4-9 9-9v9h9Z" /><path d="M12 3a9 9 0 0 1 9 9" /></IconBase>;
}

export function Pencil(props: IconProps) {
  return <IconBase {...props}><path d="M17 3a2.8 2.8 0 0 1 4 4L7.5 20.5 2 22l1.5-5.5Z" /><path d="m15 5 4 4" /></IconBase>;
}

export function RadioTower(props: IconProps) {
  return <IconBase {...props}><path d="M4.9 16.1a10 10 0 0 1 0-8.2" /><path d="M7.8 13.2a6 6 0 0 1 0-2.4" /><path d="M16.2 10.8a6 6 0 0 1 0 2.4" /><path d="M19.1 7.9a10 10 0 0 1 0 8.2" /><path d="M12 12h.01" /><path d="M12 12v8" /></IconBase>;
}

export function Search(props: IconProps) {
  return <IconBase {...props}><circle cx="11" cy="11" r="8" /><path d="m21 21-4.3-4.3" /></IconBase>;
}

export function SearchX(props: IconProps) {
  return <IconBase {...props}><circle cx="11" cy="11" r="8" /><path d="m21 21-4.3-4.3" /><path d="m8 8 6 6" /><path d="m14 8-6 6" /></IconBase>;
}

export function Settings(props: IconProps) {
  return <IconBase {...props}><path d="M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z" /></IconBase>;
}

export function ShieldAlert(props: IconProps) {
  return <IconBase {...props}><path d="M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3v8Z" /><path d="M12 8v4" /><path d="M12 16h.01" /></IconBase>;
}

export function Store(props: IconProps) {
  return <IconBase {...props}><path d="m3 9 1-5h16l1 5" /><path d="M5 9v11h14V9" /><path d="M9 20v-6h6v6" /><path d="M3 9h18" /><path d="M8 9v3" /><path d="M16 9v3" /></IconBase>;
}

export function Sun(props: IconProps) {
  return <IconBase {...props}><circle cx="12" cy="12" r="4" /><path d="M12 2v2" /><path d="M12 20v2" /><path d="m4.9 4.9 1.4 1.4" /><path d="m17.7 17.7 1.4 1.4" /><path d="M2 12h2" /><path d="M20 12h2" /><path d="m6.3 17.7-1.4 1.4" /><path d="m19.1 4.9-1.4 1.4" /></IconBase>;
}

export function Star(props: IconProps) {
  return <IconBase {...props}><path d="m12 2 3.1 6.3 6.9 1-5 4.9 1.2 6.8L12 17.8 5.8 21 7 14.2 2 9.3l6.9-1L12 2Z" /></IconBase>;
}

export function Table2(props: IconProps) {
  return <IconBase {...props}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 10h18" /><path d="M10 4v16" /></IconBase>;
}

export function Tag(props: IconProps) {
  return <IconBase {...props}><path d="M12.6 2H4a2 2 0 0 0-2 2v8.6a2 2 0 0 0 .6 1.4l7.4 7.4a2 2 0 0 0 2.8 0l8.6-8.6a2 2 0 0 0 0-2.8L14 2.6A2 2 0 0 0 12.6 2Z" /><path d="M7 7h.01" /></IconBase>;
}

export function Trash2(props: IconProps) {
  return <IconBase {...props}><path d="M3 6h18" /><path d="M8 6V4h8v2" /><path d="m19 6-1 14H6L5 6" /><path d="M10 11v6" /><path d="M14 11v6" /></IconBase>;
}

export function Upload(props: IconProps) {
  return <IconBase {...props}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="M17 8l-5-5-5 5" /><path d="M12 3v12" /></IconBase>;
}

export function Users(props: IconProps) {
  return <IconBase {...props}><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" /><path d="M22 21v-2a4 4 0 0 0-3-3.9" /><path d="M16 3.1a4 4 0 0 1 0 7.8" /></IconBase>;
}

export function X(props: IconProps) {
  return <IconBase {...props}><path d="M18 6 6 18" /><path d="m6 6 12 12" /></IconBase>;
}

