import { test } from "node:test";
import assert from "node:assert/strict";

// nav.js reads matchMedia at import time; a stub is enough for the pure helper.
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
const { toneAt } = await import("../js/nav.js");

const dark = [
  { top: 800, bottom: 1600 },
  { top: 3000, bottom: 3400 },
];

test("the bar is light above, between and below the dark sections", () => {
  assert.equal(toneAt(0, dark), "light");
  assert.equal(toneAt(799, dark), "light");
  assert.equal(toneAt(1600, dark), "light");
  assert.equal(toneAt(3400, dark), "light");
});

test("the bar is dark while a dark section is under it", () => {
  assert.equal(toneAt(800, dark), "dark");
  assert.equal(toneAt(1599, dark), "dark");
  assert.equal(toneAt(3100, dark), "dark");
});

test("with no dark sections the bar stays light", () => {
  assert.equal(toneAt(900, []), "light");
});
