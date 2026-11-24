import { Settings, X } from "./icons";
import { dateOrderOptions, type DateOrder } from "../services/datePreferences";

interface DateSettingsPanelProps {
  value: DateOrder;
  onChange: (value: DateOrder) => void;
  onClose: () => void;
}

export function DateSettingsPanel({ value, onChange, onClose }: DateSettingsPanelProps) {
  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-kaspa-background/80 px-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="date-settings-title" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="kaspa-panel w-full max-w-md rounded-md p-5 shadow-[0_20px_80px_rgba(0,0,0,0.5)]">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <span className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-kaspa-primary/40 bg-kaspa-primary/10 text-kaspa-primary">
              <Settings className="h-5 w-5" />
            </span>
            <div>
              <h2 id="date-settings-title" className="text-lg font-bold text-kaspa-text">Date display</h2>
              <p className="mt-1 text-sm text-kaspa-muted">Choose how dates are shown on KasHub.</p>
            </div>
          </div>
          <button type="button" onClick={onClose} className="focus-ring inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-kaspa-border text-kaspa-muted transition hover:border-kaspa-primary/60 hover:text-kaspa-primary" aria-label="Close date settings">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-5 space-y-2">
          {dateOrderOptions.map((option) => {
            const selected = value === option.value;
            return (
              <button key={option.value} type="button" onClick={() => onChange(option.value)} className={["focus-ring flex w-full items-center justify-between gap-4 rounded-md border px-4 py-3 text-left transition", selected ? "border-kaspa-primary bg-kaspa-primary/10 shadow-kaspa" : "border-kaspa-border bg-kaspa-background/60 hover:border-kaspa-primary/50"].join(" ")} aria-pressed={selected}>
                <span>
                  <span className={selected ? "font-bold text-kaspa-primary" : "font-semibold text-kaspa-text"}>{option.label}</span>
                  <span className="mt-1 block font-mono text-xs text-kaspa-muted">{option.example}</span>
                </span>
                <span className={["h-4 w-4 shrink-0 rounded-full border", selected ? "border-[5px] border-kaspa-primary bg-kaspa-background" : "border-kaspa-border"].join(" ")} />
              </button>
            );
          })}
        </div>

        <div className="mt-5 flex justify-end">
          <button type="button" onClick={onClose} className="focus-ring h-10 rounded-md border border-kaspa-primary/60 bg-kaspa-primary/10 px-4 text-sm font-bold text-kaspa-primary transition hover:bg-kaspa-primary hover:text-kaspa-background">Done</button>
        </div>
      </div>
    </div>
  );
}

