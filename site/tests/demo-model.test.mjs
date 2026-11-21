import { test } from "node:test";
import assert from "node:assert/strict";
import {
  coverageFraction,
  initialState,
  reduce,
  readout,
} from "../js/demo-model.js";

const stage = { x: 0, y: 0, width: 100, height: 50 };

test("coverage is the share of the stage a window hides", () => {
  assert.equal(coverageFraction(stage, { x: 50, y: 0, width: 100, height: 50 }), 0.5);
  assert.equal(coverageFraction(stage, { x: -10, y: -10, width: 200, height: 200 }), 1);
  assert.equal(coverageFraction(stage, { x: 100, y: 0, width: 40, height: 40 }), 0);
  assert.equal(coverageFraction(stage, { x: 25, y: 25, width: 50, height: 50 }), 0.25);
});

test("coverage of an empty stage is zero", () => {
  assert.equal(coverageFraction({ x: 0, y: 0, width: 0, height: 0 }, stage), 0);
});

const after = (...events) => events.reduce(reduce, initialState());

test("plays at 60 fps and about 12 mW when nothing covers it", () => {
  assert.deepEqual(readout(initialState()), {
    running: true,
    fps: 60,
    milliwatts: 12,
    speed: 1,
    status: "Playing",
  });
});

test("stops at 97% coverage and shows about 1 mW", () => {
  const r = readout(after({ type: "coverage", fraction: 0.97 }));
  assert.equal(r.running, false);
  assert.equal(r.fps, 0);
  assert.equal(r.milliwatts, 1);
  assert.equal(r.status, "Paused: covered");
});

test("keeps playing just under the threshold", () => {
  assert.equal(readout(after({ type: "coverage", fraction: 0.969 })).running, true);
});

test("stays paused until coverage falls clearly below the threshold", () => {
  const covered = after({ type: "coverage", fraction: 0.99 });
  assert.equal(readout(reduce(covered, { type: "coverage", fraction: 0.96 })).running, false);
  assert.equal(readout(reduce(covered, { type: "coverage", fraction: 0.94 })).running, true);
});

test("on battery renders 30 fps at about 7 mW", () => {
  const r = readout(after({ type: "battery", on: true }));
  assert.equal(r.fps, 30);
  assert.equal(r.milliwatts, 7);
  assert.equal(r.status, "Playing on battery");
});

test("covered on battery is still fully paused", () => {
  const r = readout(after({ type: "battery", on: true }, { type: "coverage", fraction: 1 }));
  assert.equal(r.fps, 0);
  assert.equal(r.milliwatts, 1);
});

test("locking eases playback to a stop over about a second", () => {
  const locked = after({ type: "lock", on: true });
  assert.equal(readout(locked).running, true);
  assert.equal(readout(locked).status, "Easing out");

  const halfway = readout(reduce(locked, { type: "tick", seconds: 0.5 }));
  assert.equal(halfway.running, true);
  assert.ok(halfway.speed > 0 && halfway.speed < 1, `speed ${halfway.speed}`);
  assert.equal(halfway.fps, 60);

  const stopped = readout(reduce(locked, { type: "tick", seconds: 1 }));
  assert.deepEqual(stopped, {
    running: false,
    fps: 0,
    milliwatts: 1,
    speed: 0,
    status: "Paused: locked",
  });
});

test("unlocking resumes at once and eases back to full speed", () => {
  const stopped = after({ type: "lock", on: true }, { type: "tick", seconds: 2 });
  const unlocked = reduce(stopped, { type: "lock", on: false });
  assert.equal(readout(unlocked).running, true);
  assert.equal(readout(unlocked).speed, 0);
  assert.equal(readout(unlocked).status, "Easing in");
  assert.equal(readout(reduce(unlocked, { type: "tick", seconds: 0.4 })).speed < 1, true);
  assert.equal(readout(reduce(unlocked, { type: "tick", seconds: 1 })).status, "Playing");
});

test("ticks never push speed outside 0 to 1", () => {
  const r = readout(after({ type: "tick", seconds: 5 }));
  assert.equal(r.speed, 1);
  const s = readout(after({ type: "lock", on: true }, { type: "tick", seconds: 9 }));
  assert.equal(s.speed, 0);
});

test("ignores events it does not know", () => {
  const state = initialState();
  assert.equal(reduce(state, { type: "nope" }), state);
});

test("a covered wallpaper skips the lock ramp because nobody sees it", () => {
  const covered = after({ type: "coverage", fraction: 1 }, { type: "lock", on: true });
  const uncovered = reduce(covered, { type: "coverage", fraction: 0 });
  assert.equal(readout(uncovered).status, "Paused: locked");

  const unlocked = reduce(covered, { type: "lock", on: false });
  assert.equal(readout(reduce(unlocked, { type: "coverage", fraction: 0 })).status, "Playing");
});
