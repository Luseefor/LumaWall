import { bufferedAhead, canCrossfade, cardPlays, clipSources, nextIndex, shouldPlay } from "./video-model.js";

const CYCLE_MS = 5200;
const FADE_MS = 1300; // a little longer than the CSS crossfade

/**
 * Clips carry data-src so nothing downloads until one is about to play. Then
 * they get <source> elements: the 960 px copy first on phones and small tiles,
 * the original after it. A copy that is missing just fails over to the next.
 */
function attach(video) {
  const { src } = video.dataset;
  if (!src) return;
  delete video.dataset.src;
  const options = {
    elementWidth: video.getBoundingClientRect().width,
    viewportWidth: innerWidth,
    dpr: devicePixelRatio || 1,
  };
  for (const { src: url, media } of clipSources(src, options)) {
    const source = document.createElement("source");
    source.src = url;
    source.type = "video/mp4";
    if (media) source.media = media;
    video.append(source);
  }
  video.load();
}

/**
 * Start a clip. If the browser refuses (iOS Low Power Mode blocks autoplay),
 * `onBlocked` is told so the page can offer a tap-to-play state instead.
 */
function play(video, onBlocked) {
  attach(video);
  video.play()?.catch((error) => {
    if (error?.name === "NotAllowedError") onBlocked?.();
  });
}

const ready = (video) =>
  canCrossfade({ readyState: video.readyState, bufferedAhead: bufferedAhead(video), duration: video.duration });

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
export function setUpVideos(reducedMotion, { saveData = false } = {}) {
  const players = [];
  const pauseButton = document.querySelector("[data-hero-pause]");
  let paused = false;
  let blocked = false; // the browser refused to autoplay

  const common = () => ({ hidden: document.hidden, reduced: reducedMotion.matches, paused: paused || blocked });
  const onBlocked = () => {
    if (blocked) return;
    blocked = true;
    syncButton();
    syncAll();
  };

  function watch(element, onChange) {
    new IntersectionObserver((entries) => onChange(entries.at(-1).isIntersecting)).observe(element);
  }

  // A screen that crossfades between its clips.
  // With Data Saver on nothing autoplays; only a tap on a card loads a clip.
  const autoplays = (selector) => (saveData ? [] : document.querySelectorAll(selector));

  for (const root of autoplays("[data-cycle]")) {
    const layers = [...root.querySelectorAll("[data-layer]")];
    const interval = Number(root.dataset.cycle) || CYCLE_MS;
    let index = 0;
    let inView = false;
    let timer = 0;
    let waiting = null;
    let fadeUntil = 0;

    const show = (next) => {
      const previous = layers[index];
      index = next;
      waiting = null;
      fadeUntil = Date.now() + FADE_MS;
      previous.classList.remove("on");
      layers[index].classList.add("on");
      play(layers[index], onBlocked);
      // Fetch the clip after this one now, so its crossfade starts on a frame.
      const upcoming = layers[nextIndex(index, layers.length)];
      upcoming.preload = "auto";
      attach(upcoming);
      setTimeout(() => {
        if (previous !== layers[index] && previous !== waiting) previous.pause();
      }, FADE_MS);
    };

    // Crossfade only to a clip that can play through; otherwise the current
    // one stays up (a clip with no frame yet would uncover the poster).
    const advance = () => {
      if (Date.now() < fadeUntil) return; // the last crossfade is still running; the outgoing clip is about to pause
      const target = layers[nextIndex(index, layers.length)];
      if (ready(target)) return show(layers.indexOf(target));
      if (waiting === target) {
        if (target.paused) play(target);
        return;
      }
      waiting = target;
      target.preload = "auto";
      // Muted and still transparent, so playing it only starts the download (iOS ignores preload).
      // If the browser refuses, the current clip keeps looping; that is not a blocked autoplay.
      play(target);
      target.addEventListener(
        "canplaythrough",
        () => {
          if (waiting === target && timer) show(layers.indexOf(target));
        },
        { once: true },
      );
    };

    const sync = () => {
      clearInterval(timer);
      timer = 0;
      waiting = null;
      if (shouldPlay({ ...common(), inView })) {
        play(layers[index], onBlocked);
        timer = setInterval(advance, interval);
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
  for (const video of autoplays("[data-autoplay]")) {
    let inView = false;
    const sync = () => (shouldPlay({ ...common(), inView }) ? play(video, onBlocked) : stop(video, common().reduced));
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
      const running = cardPlays({
        ...common(),
        ...state,
        saveData,
        hovered: (state.hovered || state.focused) && !state.muted,
      });
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
    pauseButton.hidden = reducedMotion.matches || saveData;
    const stopped = paused || blocked;
    pauseButton.setAttribute("aria-pressed", String(stopped));
    pauseButton.querySelector("[data-label]").textContent = stopped ? "Play wallpapers" : "Pause wallpapers";
  }

  if (pauseButton) pauseButton.disabled = false;
  pauseButton?.addEventListener("click", () => {
    // A tap is a user gesture, so it is also the way out of a blocked autoplay.
    paused = blocked ? false : !paused;
    blocked = false;
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
