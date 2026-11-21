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

import { canCrossfade, clipSources } from "../js/video-model.js";

test("Data Saver ignores hover but honours a tap", () => {
  const base = { inView: true, hidden: false, reduced: false, hovered: true, toggled: false };
  assert.equal(cardPlays({ ...base, saveData: true }), false);
  assert.equal(cardPlays({ ...base, saveData: false }), true);
  assert.equal(cardPlays({ ...base, hovered: false, toggled: true, saveData: true }), true);
});

test("a clip only fades in once it can play through", () => {
  assert.equal(canCrossfade({ readyState: 4 }), true);
  assert.equal(canCrossfade({ readyState: 3, bufferedAhead: 5, duration: 20 }), true);
  assert.equal(canCrossfade({ readyState: 3, bufferedAhead: 1, duration: 20 }), false);
  assert.equal(canCrossfade({ readyState: 3, bufferedAhead: 2, duration: 2 }), true);
  assert.equal(canCrossfade({ readyState: 1 }), false);
  assert.equal(canCrossfade({ readyState: 0 }), false);
});

test("phones and small tiles get the 960 clip, large screens the original, always with a fallback", () => {
  const phone = clipSources("media/wall-1.mp4", { viewportWidth: 390, dpr: 3, elementWidth: 320 });
  assert.deepEqual(phone.map((s) => s.src), ["media/wall-1-960.mp4", "media/wall-1.mp4"]);
  const tile = clipSources("media/wall-1.mp4", { viewportWidth: 1440, dpr: 2, elementWidth: 380 });
  assert.deepEqual(tile.map((s) => s.src), ["media/wall-1-960.mp4", "media/wall-1.mp4"]);
  const hero = clipSources("media/wall-1.mp4", { viewportWidth: 1440, dpr: 2, elementWidth: 760 });
  assert.deepEqual(hero.map((s) => s.src), ["media/wall-1.mp4"]);
  assert.deepEqual(clipSources("media/wall-portrait.mp4", { viewportWidth: 390 }).map((s) => s.src), [
    "media/wall-portrait-960.mp4",
    "media/wall-portrait.mp4",
  ]);
});
