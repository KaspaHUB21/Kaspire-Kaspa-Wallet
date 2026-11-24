export function DirectionalPercent({ value }: { value: number | null | undefined }) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return <>n/a</>;
  }
  const arrow = value > 0 ? "▲" : value < 0 ? "▼" : "";
  const formatted = new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 2
  }).format(Math.abs(value)) + "%";
  return (
    <>
      {arrow ? <span className={["mr-1 inline-block text-[9px] leading-none", value > 0 ? "translate-y-[-2.5px]" : "align-[0.08em]"].join(" ")}>{arrow}</span> : null}
      {formatted}
    </>
  );
}

