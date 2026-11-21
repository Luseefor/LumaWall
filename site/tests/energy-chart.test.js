import assert from "node:assert/strict";
import test from "node:test";
import { energyData, layoutBars } from "../js/energy-chart.js";

test("exports the three measured power values in display order", () => {
  assert.deepEqual(energyData, [
    { label: "Playing, Full quality", value: 12 },
    { label: "Playing, battery tier", value: 7 },
    { label: "Paused (covered, locked or asleep)", value: 1 },
  ]);
});

test("lays out proportional bars from zero and preserves input order", () => {
  const data = [energyData[2], energyData[0], energyData[1]];
  const bars = layoutBars(data, 240);

  assert.deepEqual(bars.map(({ width }) => width), [20, 240, 140]);
  assert.deepEqual(bars.map(({ label, value }) => ({ label, value })), data);
  assert.ok(bars.every(({ x }) => x === 0));
  assert.ok(bars[1].y > bars[0].y && bars[2].y > bars[1].y);
});

test("keeps bars within bounds at narrow, wide and zero widths", () => {
  for (const width of [0, 160, 920]) {
    for (const bar of layoutBars(energyData, width)) {
      assert.ok(bar.width >= 0 && bar.x + bar.width <= width);
    }
  }
});

test("lays out all-zero data without dividing by zero", () => {
  const [bar] = layoutBars([{ label: "Idle", value: 0 }], 240);
  assert.equal(bar.width, 0);
});
