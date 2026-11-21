import { test } from "node:test";
import assert from "node:assert/strict";
import { cardPlays, nextIndex, shouldPlay } from "../js/video-model.js";

const base = { inView: true, hidden: false, reduced: false, paused: false };

test("autoplay needs a visible tab, the video in view and no opt-out", () => {
  assert.equal(shouldPlay(base), true);
  assert.equal(shouldPlay({ ...base, inView: false }), false);
  assert.equal(shouldPlay({ ...base, hidden: true }), false);
  assert.equal(shouldPlay({ ...base, reduced: true }), false);
  assert.equal(shouldPlay({ ...base, paused: true }), false);
});

test("a card plays on hover, or when tapped on", () => {
  const card = { inView: true, hidden: false, reduced: false, hovered: false, toggled: false };
  assert.equal(cardPlays(card), false);
  assert.equal(cardPlays({ ...card, hovered: true }), true);
  assert.equal(cardPlays({ ...card, toggled: true }), true);
  assert.equal(cardPlays({ ...card, toggled: true, hidden: true }), false);
  assert.equal(cardPlays({ ...card, toggled: true, inView: false }), false);
});

test("reduced motion ignores hover but honours an explicit tap", () => {
  const card = { inView: true, hidden: false, reduced: true, hovered: true, toggled: false };
  assert.equal(cardPlays(card), false);
  assert.equal(cardPlays({ ...card, toggled: true }), true);
});

test("the cycle wraps around", () => {
  assert.equal(nextIndex(0, 3), 1);
  assert.equal(nextIndex(2, 3), 0);
  assert.equal(nextIndex(0, 1), 0);
});
