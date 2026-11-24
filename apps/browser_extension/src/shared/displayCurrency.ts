export const currencies = ['USD','EUR','GBP','AUD','CAD','JPY','CNY','CHF','INR','BRL','KRW'] as const;
export function isDisplayCurrency(value: unknown): value is typeof currencies[number] {
  return typeof value === 'string' && (currencies as readonly string[]).includes(value);
}
