import { AlertTriangle } from "./icons";
import type { TokenSourceStatus } from "../types/token";

interface SourceRibbonProps {
  mode?: TokenSourceStatus;
  warnings?: string[];
}

export function SourceRibbon({ mode, warnings = [] }: SourceRibbonProps) {
  if (!mode || mode === "LIVE") {
    return null;
  }

  return (
    <div className="mb-5 flex flex-wrap items-center gap-3 rounded-md border border-kaspa-border bg-kaspa-card px-4 py-3 text-sm text-kaspa-muted">
      <AlertTriangle className="h-4 w-4 text-kaspa-primary" aria-hidden="true" />
      <span className="font-semibold text-kaspa-text">{mode}</span>
      {warnings.slice(0, 2).map((warning) => (
        <span key={warning}>{warning}</span>
      ))}
    </div>
  );
}

