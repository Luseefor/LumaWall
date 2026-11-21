import { setUpNav } from "./nav.js";
import { setUpVideos } from "./videos.js";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

/** Run once the page has loaded and the browser has nothing better to do. */
function whenIdle(task) {
  const run = () => (window.requestIdleCallback ? requestIdleCallback(task, { timeout: 2500 }) : setTimeout(task, 200));
  if (document.readyState === "complete") run();
  else addEventListener("load", run, { once: true });
}

/** Run `task` when `element` is near the viewport, and only once. */
function whenNear(element, task, margin = "600px") {
  if (!element) return;
  const observer = new IntersectionObserver(
    (entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      task(element);
    },
    { rootMargin: margin },
  );
  observer.observe(element);
}

// Fade sections in as they scroll into view. Only when motion is welcome, and
// only for what starts below the fold, so nothing is ever left hidden.
function setUpReveal() {
  if (reducedMotion.matches) return;
  const items = document.querySelectorAll("[data-reveal]");
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px" },
  );
  for (const item of items) {
    if (item.getBoundingClientRect().top < innerHeight) continue;
    item.classList.add("will-reveal");
    observer.observe(item);
  }
}

setUpNav();
setUpReveal();

// Clips start after load. With Data Saver on, the posters stay.
if (navigator.connection?.saveData) {
  document.querySelector("[data-hero-pause]")?.setAttribute("hidden", "");
} else {
  whenIdle(() => setUpVideos(reducedMotion));
}

// The demo draws with WebGL and the chart builds an SVG; neither is needed until the reader gets near.
whenNear(document.querySelector("[data-demo]"), async (demo) => {
  const { setUpDemo } = await import("./demo.js");
  setUpDemo(demo, reducedMotion);
});
whenNear(document.querySelector("[data-energy-chart]"), async (chart) => {
  const { mountEnergyChart } = await import("./energy-chart.js");
  mountEnergyChart(chart);
});
