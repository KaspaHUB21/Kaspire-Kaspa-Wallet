export interface ChartScale { low: number; high: number; step: number; ticks: number[] }

/** Rounded, shared grid/axis values. Never manufacture observations for a gap. */
export function chartScale(values: number[]): ChartScale | null {
  const valid = values.filter(v => Number.isFinite(v) && v >= 0);
  if (!valid.length) return null;
  const min = valid.reduce((a, b) => Math.min(a, b));
  const max = valid.reduce((a, b) => Math.max(a, b));
  const padding = max > min ? (max - min) * .08 : Math.max(max * .01, 1e-12);
  const bottom = Math.max(0, min - padding), top = max + padding;
  const rawStep = (top - bottom) / 4;
  const magnitude = 10 ** Math.floor(Math.log10(rawStep));
  const fraction = rawStep / magnitude;
  const step = ([1, 2, 2.5, 5, 10].find(v => v >= fraction) ?? 10) * magnitude;
  if (!Number.isFinite(step) || step <= 0) return null;
  const low = Math.floor(bottom / step) * step, high = Math.ceil(top / step) * step;
  if (!Number.isFinite(high) || high <= low) return null;
  const count = Math.round((high - low) / step);
  const ticks = Array.from({length: Math.min(count + 1, 10)}, (_, i) => Number((high - i * step).toPrecision(15)));
  return {low, high, step, ticks};
}

export function axisUnit(mode: 'price' | 'hashrate', high: number) {
  if (mode === 'price') return {label: 'USD', divisor: 1};
  return [
    {label: 'EH/s', divisor: 1e15}, {label: 'PH/s', divisor: 1e12},
    {label: 'TH/s', divisor: 1e9}, {label: 'GH/s', divisor: 1e6},
    {label: 'MH/s', divisor: 1e3}, {label: 'kH/s', divisor: 1},
    {label: 'H/s', divisor: .001}
  ].find(unit => high >= unit.divisor) ?? {label: 'H/s', divisor: .001};
}

export function axisNumber(value: number, step: number) {
  const exponent = Math.floor(Math.log10(step));
  const halfStep = Math.abs(step / 10 ** exponent - 2.5) < 1e-7;
  const digits = Math.max(0, -exponent + (halfStep ? 1 : 0));
  if (digits > 10 || Math.abs(value) >= 1e7) return value.toExponential(4);
  return new Intl.NumberFormat('en-US', {minimumFractionDigits: digits, maximumFractionDigits: digits}).format(value);
}
