import { cardPlays, nextIndex, shouldPlay } from "./video-model.js";

const CYCLE_MS = 5200;
const FADE_MS = 1300; // a little longer than the CSS crossfade

/** Clips carry data-src so nothing downloads until one is about to play. */
function attach(video) {
  const { src } = video.dataset;
  if (!src) return;
  video.src = src;
  delete video.dataset.src;
}

function play(video) {
  attach(video);
  video.play()?.catch(() => {});
}

/** Pause, and under reduced motion fall back to the poster instead of a frozen frame. */
function stop(video, reduced) {
  video.pause();
  if (reduced && video.currentTime > 0) video.load();
}

/**
 * Wallpaper clips on the page: screens that cycle through clips, single
 * looping clips, and gallery cards that play on hover or tap. Every clip
 * plays only while it is in view and the tab is visible.
 */
export function setUpVideos(reducedMotion) {
  const players = [];
  const pauseButton = document.querySelector("[data-hero-pause]");
  let paused = false;

  const common = () => ({ hidden: document.hidden, reduced: reducedMotion.matches, paused });

  function watch(element, onChange) {
    new IntersectionObserver((entries) => onChange(entries.at(-1).isIntersecting)).observe(element);
  }

  // A screen that crossfades between its clips.
  for (const root of document.querySelectorAll("[data-cycle]")) {
    const layers = [...root.querySelectorAll("[data-layer]")];
    const interval = Number(root.dataset.cycle) || CYCLE_MS;
    let index = 0;
    let inView = false;
    let timer = 0;

    const show = (next) => {
      const previous = layers[index];
      index = next;
      previous.classList.remove("on");
      layers[index].classList.add("on");
      play(layers[index]);
      // Fetch the clip after this one now, so its crossfade starts on a frame.
      const upcoming = layers[nextIndex(index, layers.length)];
      upcoming.preload = "auto";
      attach(upcoming);
      setTimeout(() => {
        if (previous !== layers[index]) previous.pause();
      }, FADE_MS);
    };

    const sync = () => {
      clearInterval(timer);
      if (shouldPlay({ ...common(), inView })) {
        play(layers[index]);
        timer = setInterval(() => show(nextIndex(index, layers.length)), interval);
        return;
      }
      for (const layer of layers) stop(layer, common().reduced);
      if (common().reduced && index !== 0) {
        layers[index].classList.remove("on");
        layers[(index = 0)].classList.add("on");
      }
    };

    watch(root, (visible) => {
      inView = visible;
      sync();
    });
    players.push(sync);
  }

  // A single clip that loops while it is on screen.
  for (const video of document.querySelectorAll("[data-autoplay]")) {
    let inView = false;
    const sync = () => (shouldPlay({ ...common(), inView }) ? play(video) : stop(video, common().reduced));
    watch(video, (visible) => {
      inView = visible;
      sync();
    });
    players.push(sync);
  }

  // Gallery cards: hover or focus plays a clip, a tap or Enter keeps it playing.
  const cards = [...document.querySelectorAll("[data-card]")].map((card) => {
    const video = card.querySelector("video");
    const state = { inView: false, hovered: false, focused: false, toggled: false, muted: false };
    const sync = () => {
      const running = cardPlays({ ...common(), ...state, hovered: (state.hovered || state.focused) && !state.muted });
      card.classList.toggle("is-playing", running);
      card.setAttribute("aria-pressed", String(state.toggled));
      if (running) play(video);
      else stop(video, common().reduced);
    };
    watch(card, (visible) => {
      state.inView = visible;
      sync();
    });
    card.addEventListener("pointerenter", (e) => {
      if (e.pointerType !== "mouse") return;
      state.hovered = true;
      sync();
    });
    card.addEventListener("pointerleave", () => {
      state.hovered = false;
      state.muted = false;
      sync();
    });
    card.addEventListener("focus", () => {
      state.focused = card.matches(":focus-visible");
      sync();
    });
    card.addEventListener("blur", () => {
      state.focused = false;
      state.muted = false;
      sync();
    });
    card.addEventListener("click", () => {
      const on = !state.toggled;
      for (const other of cards) other.set(false);
      state.toggled = on;
      // Tapping a playing card pauses it even while the pointer or focus is still on it.
      state.muted = !on;
      sync();
    });
    const set = (toggled) => {
      state.toggled = toggled;
      sync();
    };
    players.push(sync);
    return { set };
  });

  const syncAll = () => players.forEach((sync) => sync());

  function syncButton() {
    if (!pauseButton) return;
    pauseButton.hidden = reducedMotion.matches;
    pauseButton.setAttribute("aria-pressed", String(paused));
    pauseButton.querySelector("[data-label]").textContent = paused ? "Play wallpapers" : "Pause wallpapers";
  }

  pauseButton?.addEventListener("click", () => {
    paused = !paused;
    syncButton();
    syncAll();
  });
  document.addEventListener("visibilitychange", syncAll);
  reducedMotion.addEventListener("change", () => {
    syncButton();
    syncAll();
  });
  syncButton();
}
