import { coverageFraction, initialState, reduce, readout } from "./demo-model.js";
import { Wallpaper, createLoop } from "./wallpaper.js";

// Window size and positions as fractions of the stage. The window is a bit
// larger than the stage so it can hide all of it without pixel-perfect aim.
const SIZE = 1.06;
const START = { x: 0.44, y: 0.4 };
const COVERED = { x: -0.03, y: -0.03 };
const LIMITS = { minX: -0.6, maxX: 0.86, minY: -SIZE + 1, maxY: 0.84 };
const KEY_STEP = 0.02;

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** Animate a number in `el` toward `to`; jumps when motion is reduced. */
function counter(el, reducedMotion) {
  let shown = Number(el.textContent) || 0;
  let target = shown;
  let raf = 0;
  return (to) => {
    if (to === target) return;
    target = to;
    cancelAnimationFrame(raf);
    if (reducedMotion.matches) {
      el.textContent = shown = to;
      return;
    }
    const from = shown;
    const start = performance.now();
    const step = (now) => {
      const t = Math.min(1, (now - start) / 400);
      shown = from + (to - from) * (1 - (1 - t) ** 3);
      el.textContent = Math.round(shown);
      if (t < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
  };
}

export function setUpDemo(root, reducedMotion) {
  const stage = root.querySelector("[data-stage]");
  const canvas = stage.querySelector("canvas");
  const win = root.querySelector("[data-window]");
  const status = root.querySelector("[data-status]");
  const coverOut = root.querySelector("[data-cover]");
  const batterySwitch = root.querySelector("[data-battery]");
  const lockSwitch = root.querySelector("[data-lock]");
  const stillNote = root.querySelector("[data-still-note]");
  const showFps = counter(root.querySelector("[data-fps]"), reducedMotion);
  const showMw = counter(root.querySelector("[data-mw]"), reducedMotion);

  const wall = new Wallpaper(canvas, { scale: 0.6, maxPixelRatio: 1.5 });
  if (!wall.ok) stage.classList.add("no-webgl");

  let state = initialState();
  let pos = { ...START };
  let inView = false;
  let glide = 0;

  // With no live scene, readouts follow the model instead of counted frames.
  const live = () => wall.ok && !reducedMotion.matches;

  const loop = createLoop(
    (time, dt) => {
      wall.draw(time);
      if (dt > 0) dispatch({ type: "tick", seconds: dt });
    },
    { startTime: 120, onStats: (fps) => live() && readout(state).running && showFps(fps) },
  );

  function dispatch(event) {
    const next = reduce(state, event);
    if (next === state) return;
    state = next;
    render();
  }

  function render() {
    // Without a live loop nothing advances the lock ramp, so settle it.
    if (!live() && state.progress !== (state.locked ? 0 : 1)) return dispatch({ type: "tick", seconds: 5 });
    const r = readout(state);
    loop.setFps(r.fps || 60);
    loop.setSpeed(r.speed);
    showMw(r.milliwatts);
    // A running live loop reports its own frame count; otherwise the model decides.
    if (!live() || !r.running) showFps(r.fps);
    if (status.textContent !== r.status) status.textContent = r.status;
    stillNote.hidden = live();
    if (r.running && inView && !document.hidden && live()) loop.start();
    else loop.stop();
  }

  function place() {
    const { width, height } = stage.getBoundingClientRect();
    win.style.transform = `translate(${pos.x * width}px, ${pos.y * height}px)`;
    const fraction = coverageFraction(
      { x: 0, y: 0, width: 1, height: 1 },
      { x: pos.x, y: pos.y, width: SIZE, height: SIZE },
    );
    // Round down so the readout never shows 97% while still playing.
    coverOut.textContent = Math.floor(fraction * 100);
    dispatch({ type: "coverage", fraction });
  }

  function moveTo(x, y) {
    pos = { x: clamp(x, LIMITS.minX, LIMITS.maxX), y: clamp(y, LIMITS.minY, LIMITS.maxY) };
    place();
  }

  function glideTo(target) {
    cancelAnimationFrame(glide);
    if (reducedMotion.matches) return moveTo(target.x, target.y);
    const from = { ...pos };
    const start = performance.now();
    const step = (now) => {
      const t = Math.min(1, (now - start) / 450);
      const e = t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2;
      moveTo(from.x + (target.x - from.x) * e, from.y + (target.y - from.y) * e);
      if (t < 1) glide = requestAnimationFrame(step);
    };
    glide = requestAnimationFrame(step);
  }

  // Dragging with mouse, pen or touch.
  let drag = null;
  win.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    cancelAnimationFrame(glide);
    win.setPointerCapture(e.pointerId);
    win.classList.add("dragging");
    const { width, height } = stage.getBoundingClientRect();
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, from: { ...pos }, width, height };
  });
  win.addEventListener("pointermove", (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    moveTo(drag.from.x + (e.clientX - drag.x) / drag.width, drag.from.y + (e.clientY - drag.y) / drag.height);
  });
  const endDrag = (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    drag = null;
    win.classList.remove("dragging");
  };
  win.addEventListener("pointerup", endDrag);
  win.addEventListener("pointercancel", endDrag);

  // Arrow keys move the focused window; Shift moves it further.
  win.addEventListener("keydown", (e) => {
    const step = e.shiftKey ? KEY_STEP * 5 : KEY_STEP;
    const moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    const move = moves[e.key];
    if (!move) return;
    e.preventDefault();
    cancelAnimationFrame(glide);
    moveTo(pos.x + move[0], pos.y + move[1]);
  });

  root.querySelector("[data-cover-button]").addEventListener("click", () => glideTo(COVERED));
  root.querySelector("[data-uncover-button]").addEventListener("click", () => glideTo(START));

  for (const [el, type] of [
    [batterySwitch, "battery"],
    [lockSwitch, "lock"],
  ]) {
    el.addEventListener("click", () => {
      const on = el.getAttribute("aria-checked") !== "true";
      el.setAttribute("aria-checked", String(on));
      dispatch({ type, on });
    });
  }

  new ResizeObserver(() => {
    place();
    // Resizing clears the canvas, so a paused wallpaper needs one still frame.
    if (wall.ok && wall.resize() && !loop.running) wall.draw(loop.time);
  }).observe(stage);
  new IntersectionObserver(([entry]) => {
    inView = entry.isIntersecting;
    render();
  }).observe(stage);
  document.addEventListener("visibilitychange", render);
  reducedMotion.addEventListener("change", render);

  wall.onContextChange = () => {
    stage.classList.toggle("no-webgl", !wall.ok);
    if (wall.ok && !loop.running) wall.draw(loop.time);
    render();
  };

  wall.resize();
  wall.draw(loop.time);
  place();
  render();
}
