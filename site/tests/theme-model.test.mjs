import { test } from "node:test";
import assert from "node:assert/strict";
import { attributeFor, normalizeChoice } from "../js/theme-model.js";

test("only system, light and dark are accepted from storage", () => {
  assert.equal(normalizeChoice("light"), "light");
  assert.equal(normalizeChoice("dark"), "dark");
  assert.equal(normalizeChoice("system"), "system");
  for (const bad of [null, undefined, "", "Dark", "sepia", "<script>"]) assert.equal(normalizeChoice(bad), "system");
});

test("system sets no attribute so the media query decides", () => {
  assert.equal(attributeFor("system"), null);
  assert.equal(attributeFor("light"), "light");
  assert.equal(attributeFor("dark"), "dark");
});
