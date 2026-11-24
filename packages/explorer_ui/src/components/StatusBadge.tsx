import { CheckCircle2, CircleDashed } from "./icons";

interface StatusBadgeProps {
  verified: boolean;
  reason?: string;
}

export function StatusBadge({ verified, reason }: StatusBadgeProps) {
  const label = verified ? "Market activity verified" : "Market activity unverified";
  const explanation = `${label}. ${reason || (verified ? "Market activity meets the explorer criteria." : "Activity volume is insufficient or price data is unavailable.")} This is not technical profile verification or a security audit.`;
  return (
    <span
      className={[
        "inline-flex h-7 w-7 items-center justify-center rounded-md border",
        verified
          ? "border-kaspa-primary/60 bg-kaspa-primary/10 text-kaspa-primary"
          : "border-kaspa-border bg-kaspa-background/50 text-kaspa-muted"
      ].join(" ")}
      title={explanation}
      aria-label={label}
    >
      {verified ? <CheckCircle2 className="h-4 w-4" aria-hidden="true" /> : <CircleDashed className="h-4 w-4" aria-hidden="true" />}
    </span>
  );
}

