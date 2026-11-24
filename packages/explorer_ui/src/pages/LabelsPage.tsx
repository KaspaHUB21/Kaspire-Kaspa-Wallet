import { ChangeEvent, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { AlertTriangle, ArrowLeft, Download, Search, Tag, Trash2, Upload } from "../components/icons";
import { useWalletLabels, type WalletLabel } from "../services/walletLabels";
import { downloadText } from "../utils/download";
import { formatDateTime } from "../utils/format";

function walletHref(address: string) {
  const normalized = address.trim().toLowerCase();
  return "/wallet/krc20/" + encodeURIComponent(address);
}

export function LabelsPage() {
  const { exportLabels, importLabels, labels, removeLabel } = useWalletLabels();
  const [query, setQuery] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const [removeCandidate, setRemoveCandidate] = useState<WalletLabel | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const filteredLabels = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    const kaspaLabels=labels.filter(item=>item.address.startsWith('kaspa:'));
    if (!normalizedQuery) return kaspaLabels;
    return kaspaLabels.filter((item) => item.label.toLowerCase().includes(normalizedQuery) || item.address.toLowerCase().includes(normalizedQuery));
  }, [labels, query]);

  function exportSavedLabels() {
    downloadText("kaspa-wallet-labels.json", exportLabels(), "application/json");
    setNotice("Labels exported");
  }

  function importSavedLabels(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const count = importLabels(String(reader.result || ""));
        setNotice(count === 1 ? "1 label imported" : `${count} labels imported`);
      } catch {
        setNotice("Import failed. Please use a valid JSON label file.");
      }
      event.target.value = "";
    };
    reader.readAsText(file);
  }

  return (
    <section>
      <Link to="/" className="focus-ring mb-5 inline-flex items-center gap-2 rounded-md text-sm font-semibold text-kaspa-muted hover:text-kaspa-primary">
        <ArrowLeft className="h-4 w-4" aria-hidden="true" /> Back
      </Link>

      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="text-sm font-bold text-kaspa-primary">Wallet labels</div>
          <h1 className="mt-1 text-2xl font-bold text-kaspa-text">Saved Labels</h1>
          <p className="mt-2 max-w-2xl text-sm text-kaspa-muted">Personal labels are stored locally in this browser and displayed next to matching wallet addresses in transaction tables.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <input ref={fileInputRef} type="file" accept="application/json,.json" onChange={importSavedLabels} className="hidden" />
          <button type="button" onClick={() => fileInputRef.current?.click()} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-border px-3 text-sm font-bold text-kaspa-text hover:border-kaspa-primary hover:text-kaspa-primary">
            <Upload className="h-4 w-4" /> Import labels
          </button>
          <button type="button" onClick={exportSavedLabels} className="focus-ring inline-flex h-10 items-center gap-2 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-3 text-sm font-bold text-kaspa-primary hover:bg-kaspa-primary hover:text-kaspa-background">
            <Download className="h-4 w-4" /> Export labels
          </button>
        </div>
      </div>

      <div className="kaspa-panel rounded-md p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <label className="relative block w-full sm:max-w-md">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-kaspa-muted" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search label or wallet"
              className="focus-ring h-11 w-full rounded-md border border-kaspa-border bg-kaspa-background pl-10 pr-3 text-sm text-kaspa-text outline-none"
            />
          </label>
          <div className="text-sm font-bold text-kaspa-muted">{labels.length} saved</div>
        </div>

        {notice ? <div className="mt-4 rounded-md border border-kaspa-primary/40 bg-kaspa-primary/10 px-4 py-3 text-sm text-kaspa-primary">{notice}</div> : null}

        <div className="explorer-card-grid mt-5 grid gap-3 sm:grid-cols-2">
          {filteredLabels.length === 0 ? <div className="p-4 text-kaspa-muted">No labels found</div> : null}
          {filteredLabels.map((item) => <article key={item.address} className="min-w-0 rounded-md border border-kaspa-border p-4">
            <h3 className="break-all font-bold text-kaspa-primary">{item.label}</h3>
            <dl className="explorer-facts mt-3 space-y-3">
              <div><dt>Wallet</dt><dd><Link to={walletHref(item.address)}>{item.address}</Link></dd></div>
              <div><dt>Updated</dt><dd>{formatDateTime(item.updatedAt)}</dd></div>
            </dl>
            <button type="button" title="Delete label" aria-label="Delete label" onClick={() => setRemoveCandidate(item)} className="focus-ring mt-3 inline-flex h-11 w-11 items-center justify-center rounded-md border border-kaspa-border text-kaspa-muted">
              <Trash2 className="h-4 w-4" />
            </button>
          </article>)}
        </div>
      </div>
      <RemoveLabelModal
        label={removeCandidate}
        onCancel={() => setRemoveCandidate(null)}
        onConfirm={() => {
          if (removeCandidate) {
            removeLabel(removeCandidate.address);
            setNotice(`Label "${removeCandidate.label}" deleted`);
          }
          setRemoveCandidate(null);
        }}
      />
    </section>
  );
}

function RemoveLabelModal({ label, onCancel, onConfirm }: { label: WalletLabel | null; onCancel: () => void; onConfirm: () => void }) {
  if (!label) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-kaspa-background/80 px-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="remove-label-title">
      <div className="kaspa-panel w-full max-w-md rounded-md p-5 shadow-[0_20px_80px_rgba(0,0,0,0.45)]">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-red-300/50 bg-red-400/10 text-red-300">
            <AlertTriangle className="h-5 w-5" aria-hidden="true" />
          </div>
          <div className="min-w-0">
            <h2 id="remove-label-title" className="text-lg font-bold text-kaspa-text">Delete label?</h2>
            <p className="mt-2 text-sm leading-6 text-kaspa-muted">
              This removes the saved label <span className="font-bold text-kaspa-text">{label.label}</span> from this browser. The wallet address remains untouched.
            </p>
            <p className="mt-2 break-all font-mono text-xs text-kaspa-muted">{label.address}</p>
          </div>
        </div>
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button type="button" onClick={onCancel} className="focus-ring h-10 rounded-md border border-kaspa-border px-4 text-sm font-bold text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
            Cancel
          </button>
          <button type="button" onClick={onConfirm} className="focus-ring inline-flex h-10 items-center justify-center gap-2 rounded-md border border-red-300/70 bg-red-400/10 px-4 text-sm font-bold text-red-200 hover:bg-red-400/20">
            <Trash2 className="h-4 w-4" aria-hidden="true" /> Delete
          </button>
        </div>
      </div>
    </div>
  );
}

