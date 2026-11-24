import { getDateOrder } from "../services/datePreferences";

export function formatCurrency(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "Currently unavailable";
  }
  const absolute = Math.abs(value);
  const leadingDecimalZeros = absolute > 0 && absolute < 1
    ? Math.max(0, -Math.floor(Math.log10(absolute)) - 1)
    : 0;
  if (leadingDecimalZeros >= 4) {
    return `${value < 0 ? "-" : ""}$${formatPortfolioNumber(absolute)}`;
  }
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    notation: Math.abs(value) >= 100000 ? "compact" : "standard",
    maximumFractionDigits: value < 1 ? 6 : 2
  }).format(value);
}

export function formatKas(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: value < 1 ? 6 : 2,
    notation: Math.abs(value) >= 100000 ? "compact" : "standard"
  }).format(value) + " KAS";
}

export function formatKasVolume(value: number | null | undefined) {
  return formatKas(value ?? 0);
}

export function formatSignedKas(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const prefix = value > 0 ? "+" : value < 0 ? "-" : "";
  return prefix + formatKas(Math.abs(value));
}

export function formatSignedCurrency(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "Currently unavailable";
  }
  const prefix = value > 0 ? "+" : value < 0 ? "-" : "";
  return prefix + formatCurrency(Math.abs(value));
}

export function formatCompact(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 1
  }).format(value);
}

export function formatInteger(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 0
  }).format(value);
}

export function formatCurrencyWindow(value: number | null | undefined, available = true) {
  if (!available) {
    return "\u2014";
  }
  return formatCurrency(value);
}

export function formatTokenAmount(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: value < 1 ? 8 : 4
  }).format(value);
}

const subscriptDigits: Record<string, string> = {
  "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
  "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉"
};

export function formatPortfolioNumber(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "n/a";
  }
  if (value === 0) {
    return "0";
  }

  const absolute = Math.abs(value);
  const exponent = Math.floor(Math.log10(absolute));
  const leadingDecimalZeros = exponent < 0 ? -exponent - 1 : 0;
  if (leadingDecimalZeros >= 4) {
    const digits = absolute.toExponential(3).split("e")[0].replace(".", "");
    const subscript = String(leadingDecimalZeros).split("").map((digit) => subscriptDigits[digit]).join("");
    return `${value < 0 ? "-" : ""}0.0${subscript}${digits}`;
  }

  return new Intl.NumberFormat("en-US", {
    notation: "standard",
    useGrouping: true,
    maximumSignificantDigits: 4,
    maximumFractionDigits: 20
  }).format(value);
}

export function formatPortfolioKas(value: number | null | undefined) {
  const formatted = formatPortfolioNumber(value);
  return formatted === "n/a" ? formatted : `${formatted} KAS`;
}

export function formatPortfolioCurrency(value: number | null | undefined) {
  const formatted = formatPortfolioNumber(value);
  return formatted === "n/a" ? "Currently unavailable" : `$${formatted}`;
}

export function formatPortfolioSignedKas(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "n/a";
  }
  const prefix = value > 0 ? "+" : value < 0 ? "-" : "";
  return `${prefix}${formatPortfolioNumber(Math.abs(value))} KAS`;
}

export function formatPortfolioSignedCurrency(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "Currently unavailable";
  }
  const prefix = value > 0 ? "+" : value < 0 ? "-" : "";
  return `${prefix}$${formatPortfolioNumber(Math.abs(value))}`;
}

export function formatPlainDecimal(value: string | number | null | undefined) {
  if (value === null || value === undefined || value === "") {
    return "";
  }
  const source = String(value).trim();
  const match = /^([+-]?)(\d+)(?:\.(\d*))?[eE]([+-]?\d+)$/.exec(source);
  if (!match) {
    return source;
  }
  const [, sign, integer, fraction = "", rawExponent] = match;
  const exponent = Number(rawExponent);
  const digits = integer + fraction;
  const decimalIndex = integer.length + exponent;
  if (decimalIndex <= 0) {
    return `${sign}0.${"0".repeat(-decimalIndex)}${digits}`;
  }
  if (decimalIndex >= digits.length) {
    return `${sign}${digits}${"0".repeat(decimalIndex - digits.length)}`;
  }
  return `${sign}${digits.slice(0, decimalIndex)}.${digits.slice(decimalIndex)}`;
}

export function formatKcc20Amount(value: number | null | undefined, decimals: number) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const divisor = 10 ** Math.max(0, Math.min(18, decimals));
  return formatTokenAmount(value / divisor);
}

export function formatPercent(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    style: "percent",
    maximumFractionDigits: 2
  }).format(value / 100);
}

export function formatSignedPercent(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const prefix = value > 0 ? "+" : "";
  return prefix + new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 2
  }).format(value) + "%";
}

export function formatDirectionalPercent(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  const arrow = value > 0 ? "▲" : value < 0 ? "▼" : "";
  const formatted = new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 2
  }).format(Math.abs(value)) + "%";
  return arrow ? `${arrow} ${formatted}` : formatted;
}

export function formatPlainPercent(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "n/a";
  }
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: value < 1 ? 2 : 1
  }).format(value) + "%";
}

export function formatAgeSince(value: string | null | undefined) {
  if (!value) {
    return "n/a";
  }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    return "n/a";
  }
  const ageMs = Math.max(0, Date.now() - timestamp);
  const day = 24 * 60 * 60 * 1000;
  const days = Math.floor(ageMs / day);
  if (days < 1) {
    return "today";
  }
  if (days < 30) {
    return days + "d";
  }
  const months = Math.floor(days / 30);
  if (months < 24) {
    return months + "mo";
  }
  return Math.floor(days / 365) + "y";
}

export function formatDaysSince(value: string | null | undefined) {
  if (!value) {
    return "n/a";
  }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    return "n/a";
  }
  const days = Math.floor(Math.max(0, Date.now() - timestamp) / (24 * 60 * 60 * 1000));
  return days < 1 ? "today" : `${days}d`;
}

export function formatDateTime(value: string | null | undefined) {
  if (!value) {
    return "n/a";
  }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    return "n/a";
  }
  return formatTimestamp(timestamp, true, true);
}

export function formatDateTimeSeconds(value: string | null | undefined) {
  if (!value) {
    return "n/a";
  }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    return "n/a";
  }
  return formatTimestamp(timestamp, true, true, true);
}

export function formatDate(value: string | number | Date | null | undefined) {
  const timestamp = dateTimestamp(value);
  return timestamp === null ? "n/a" : formatTimestamp(timestamp, false, true);
}

export function formatShortDate(value: string | number | Date | null | undefined) {
  const timestamp = dateTimestamp(value);
  return timestamp === null ? "n/a" : formatTimestamp(timestamp, false, false);
}

export function formatUnixDateTime(seconds: number) {
  return Number.isFinite(seconds) ? formatTimestamp(seconds * 1000, true, true) : "n/a";
}

export function formatUnixDate(seconds: number) {
  return Number.isFinite(seconds) ? formatTimestamp(seconds * 1000, false, true) : "n/a";
}

function dateTimestamp(value: string | number | Date | null | undefined) {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  const timestamp = value instanceof Date ? value.getTime() : typeof value === "number" ? value : Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function formatTimestamp(timestamp: number, includeTime: boolean, includeYear: boolean, includeSeconds = false) {
  const date = new Date(timestamp);
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const year = String(date.getFullYear());
  const order = getDateOrder();
  const datePart = includeYear
    ? order === "DMY" ? `${day}/${month}/${year}` : order === "MDY" ? `${month}/${day}/${year}` : `${year}/${month}/${day}`
    : order === "DMY" ? `${day}/${month}` : order === "MDY" ? `${month}/${day}` : `${year}/${month}/${day}`;
  if (!includeTime) {
    return datePart;
  }
  const time = new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    ...(includeSeconds ? { second: "2-digit" } : {})
  }).format(date);
  return `${datePart}, ${time}`;
}

