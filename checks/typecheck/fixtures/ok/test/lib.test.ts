import { test } from "node:test";
import assert from "node:assert/strict";
import { double } from "../lib.ts";

test("double", () => {
  assert.equal(double(2), 4);
});
