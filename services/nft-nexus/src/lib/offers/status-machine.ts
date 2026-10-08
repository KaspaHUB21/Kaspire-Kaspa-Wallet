import type { OfferStatus } from "@prisma/client";

export const TERMINAL_STATUSES: OfferStatus[] = [
  "COMPLETED_EXTERNALLY",
  "DECLINED",
  "CANCELLED_BY_BUYER",
  "EXPIRED",
  "INVALIDATED_OWNER_CHANGED",
  "INVALIDATED_NFT_UNAVAILABLE"
];

const allowedTransitions = new Map<OfferStatus, OfferStatus[]>([
  ["DRAFT", ["OPEN"]],
  ["OPEN", ["COUNTERED", "DECLINED", "CANCELLED_BY_BUYER", "EXPIRED", "AGREED_WAITING_RELIST"]],
  ["COUNTERED", ["CANCELLED_BY_BUYER", "EXPIRED", "AGREED_WAITING_RELIST"]],
  ["AGREED_WAITING_RELIST", ["RELIST_DETECTED", "EXPIRED", "INVALIDATED_OWNER_CHANGED", "INVALIDATED_NFT_UNAVAILABLE"]],
  ["RELIST_DETECTED", ["COMPLETED_EXTERNALLY", "INVALIDATED_OWNER_CHANGED", "INVALIDATED_NFT_UNAVAILABLE"]]
]);

export function assertCanTransition(from: OfferStatus, to: OfferStatus) {
  if (TERMINAL_STATUSES.includes(from)) {
    throw new Error("Terminal offers cannot be changed.");
  }

  if (!allowedTransitions.get(from)?.includes(to)) {
    throw new Error(`Invalid offer status transition: ${from} -> ${to}.`);
  }
}
