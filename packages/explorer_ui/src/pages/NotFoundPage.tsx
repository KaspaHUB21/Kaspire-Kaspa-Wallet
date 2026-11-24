import { Link } from "react-router-dom";

export function NotFoundPage() {
  return (
    <section className="kaspa-panel flex min-h-[360px] flex-col items-center justify-center rounded-md p-8 text-center">
      <h1 className="text-2xl font-bold text-kaspa-text">Not found</h1>
      <Link to="/krc20" className="focus-ring mt-4 rounded-md border border-kaspa-primary bg-kaspa-primary/10 px-4 py-2 text-sm font-bold text-kaspa-primary shadow-kaspa">KRC20 Explorer</Link>
    </section>
  );
}

