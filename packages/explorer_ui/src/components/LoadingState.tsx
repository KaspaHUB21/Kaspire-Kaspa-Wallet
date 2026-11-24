export function LoadingState() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {Array.from({ length: 6 }).map((_, index) => (
        <div key={index} className="kaspa-panel h-52 animate-pulse rounded-md" />
      ))}
    </div>
  );
}

