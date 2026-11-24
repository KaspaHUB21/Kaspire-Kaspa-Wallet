export type DateOrder = "DMY" | "MDY" | "YMD";

const storageKey = "kashub-date-order-v1";
const fallbackOrder: DateOrder = "DMY";
let sessionOrder: DateOrder | null = null;

export const dateOrderOptions: Array<{ value: DateOrder; label: string; example: string }> = [
  { value: "DMY", label: "Day / Month / Year", example: "21/07/2026" },
  { value: "MDY", label: "Month / Day / Year", example: "07/21/2026" },
  { value: "YMD", label: "Year / Month / Day", example: "2026/07/21" }
];

export function getDateOrder(): DateOrder {
  if (sessionOrder) {
    return sessionOrder;
  }
  try {
    const value = window.localStorage.getItem(storageKey);
    sessionOrder = value === "MDY" || value === "YMD" || value === "DMY" ? value : fallbackOrder;
  } catch {
    sessionOrder = fallbackOrder;
  }
  return sessionOrder;
}

export function saveDateOrder(value: DateOrder) {
  sessionOrder = value;
  try {
    window.localStorage.setItem(storageKey, value);
  } catch {
    // The selected value still applies until the current page is closed.
  }
}

