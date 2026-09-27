import assert from "node:assert/strict";
import test from "node:test";
import { rocketTokenAmountDisplay } from "./generated/kasparocket.mjs";

test("KaspaRocket SDK display amount wins over raw token units", () => {
  assert.equal(
    rocketTokenAmountDisplay({
      amountTokens: "420290",
      amountTokensDisplay: "420.29",
    }),
    "420.29",
  );
  assert.equal(
    rocketTokenAmountDisplay({
      amount_tokens: "15875064",
      amount_tokens_display: "15875.064",
    }),
    "15875.064",
  );
});

test("legacy KaspaRocket responses still receive one canonical conversion", () => {
  assert.equal(rocketTokenAmountDisplay({ amountTokens: "420290" }), "420.29");
  assert.equal(rocketTokenAmountDisplay({ amount_tokens: "1000" }), "1");
});
