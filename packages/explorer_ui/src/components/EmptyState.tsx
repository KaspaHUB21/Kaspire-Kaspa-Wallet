import { SearchX } from "./icons";

interface EmptyStateProps {
  title: string;
  body?: string;
}

export function EmptyState({ title, body }: EmptyStateProps) {
  return (
    <div className="kaspa-panel flex min-h-52 flex-col items-center justify-center rounded-md p-8 text-center">
      <SearchX className="h-8 w-8 text-kaspa-primary" aria-hidden="true" />
      <h2 className="mt-3 text-lg font-bold text-kaspa-text">{title}</h2>
      {body ? <p className="mt-2 max-w-md text-sm text-kaspa-muted">{body}</p> : null}
    </div>
  );
}

