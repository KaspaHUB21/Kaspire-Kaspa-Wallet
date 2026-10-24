import test from "node:test";
import assert from "node:assert/strict";
import { formatRawTokenAmount,formatTokenDisplay } from "./generated/tokenAmount.mjs";

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
test('US grouping is exact beyond Number precision and leaves machine amounts unchanged',()=>{
  assert.equal(formatTokenDisplay('900719925474099301',8),'9,007,199,254.74099301');
  assert.equal(formatTokenDisplay('-2105645645',5),'-21,056.45645');
  assert.equal(formatRawTokenAmount('900719925474099301',8),'9007199254.74099301');
});
