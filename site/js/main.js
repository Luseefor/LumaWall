import { Wallpaper, createLoop } from "./wallpaper.js";
import { setUpDemo } from "./demo.js";
import { mountEnergyChart } from "./energy-chart.js";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

// LumaWall's measured power for each state, in mW (see the energy chart).
const POWER = { full: 12, battery: 7, paused: 1 };

function setUpHero() {
  const hero = document.querySelector(".hero");
  const canvas = hero.querySelector("[data-hero-canvas]");
  const fpsOut = document.querySelector("[data-hud-fps]");
  const mwOut = document.querySelector("[data-hud-mw]");
  const dot = document.querySelector("[data-hud-dot]");
  const stateOut = document.querySelector("[data-hud-state]");

  const wall = new Wallpaper(canvas, { scale: 0.6, maxPixelRatio: 1 });
  if (!wall.ok) hero.classList.add("no-webgl");

  let inView = true;
  let onBattery = false;
  let userPaused = false;
  const pauseButton = document.querySelector("[data-hero-pause]");

  const loop = createLoop((time) => wall.draw(time), {
    onStats(fps) {
      fpsOut.textContent = fps;
      const running = fps > 0;
      dot.classList.toggle("on", running);
      if (stateOut) stateOut.textContent = running ? "Playing" : "Paused";
      mwOut.textContent = running ? (onBattery ? POWER.battery : POWER.full) : POWER.paused;
    },
  });

  function update() {
    const run = wall.ok && inView && !userPaused && !document.hidden && !reducedMotion.matches;
    loop.setFps(onBattery ? 30 : 60);
    if (run) loop.start();
    else loop.stop();
    // Say it in words too: with reduced motion nothing plays, whatever the button says.
    const still = reducedMotion.matches;
    pauseButton.disabled = still;
    pauseButton.textContent = still || userPaused ? "Play" : "Pause";
  }

  function redraw() {
    // Resizing clears the canvas, so a paused wallpaper needs one still frame.
    if (wall.ok && wall.resize() && !loop.running) wall.draw(loop.time);
  }

  wall.onContextChange = () => {
    hero.classList.toggle("no-webgl", !wall.ok);
    if (wall.ok && !loop.running) wall.draw(loop.time);
    update();
  };

  pauseButton.addEventListener("click", () => {
    userPaused = !userPaused;
    pauseButton.setAttribute("aria-pressed", String(userPaused));
    update();
  });

  new ResizeObserver(redraw).observe(canvas);
  new IntersectionObserver(([entry]) => {
    inView = entry.isIntersecting;
    update();
  }).observe(hero);
  document.addEventListener("visibilitychange", update);
  reducedMotion.addEventListener("change", update);

  // Like the app, drop to 30 fps when the computer runs on battery.
  navigator
    .getBattery?.()
    .then((battery) => {
      const sync = () => {
        onBattery = !battery.charging;
        update();
      };
      battery.addEventListener("chargingchange", sync);
      sync();
    })
    .catch(() => {});

  redraw();
  update();
}

setUpHero();
setUpDemo(document.querySelector("[data-demo]"), reducedMotion);

const energy = document.querySelector("[data-energy-chart]");
if (energy) mountEnergyChart(energy);
