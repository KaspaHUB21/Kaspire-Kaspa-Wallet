import test from "node:test";
import assert from "node:assert/strict";
import { formatRawTokenAmount } from "./generated/tokenAmount.mjs";

test("formats canonical 8-decimal KRC-20 amounts for activity history", () => {
  assert.equal(formatRawTokenAmount("300000000", 8), "3");
  assert.equal(formatRawTokenAmount("1", 8), "0.00000001");
  assert.equal(formatRawTokenAmount("300000001", 8), "3.00000001");
});

test("rejects malformed raw amounts and decimal counts", () => {
  assert.throws(() => formatRawTokenAmount("3.0", 8));
  assert.throws(() => formatRawTokenAmount("-1", 8));
  assert.throws(() => formatRawTokenAmount("1", 19));
});
