import { setUpDemo } from "./demo.js";
import { mountEnergyChart } from "./energy-chart.js";
import { setUpVideos } from "./videos.js";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

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

setUpVideos(reducedMotion);
setUpReveal();

const demo = document.querySelector("[data-demo]");
if (demo) setUpDemo(demo, reducedMotion);

const energy = document.querySelector("[data-energy-chart]");
if (energy) mountEnergyChart(energy);
