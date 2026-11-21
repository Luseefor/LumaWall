// The "Cover it" demo's rules, kept free of the DOM so they can be tested.

/** Coverage at which the wallpaper stops drawing. */
export const COVER_ENTER = 0.97;
/**
 * Once paused, coverage must drop below this to resume. The app keeps the
 * same kind of gap so a window resting on the threshold doesn't strobe.
 */
export const COVER_RELEASE = 0.95;
/** Seconds the lock ramp takes from full speed to a stop, and back. */
export const RAMP_SECONDS = 1;

// LumaWall's own processes, measured on one M-series MacBook.
const MILLIWATTS = { full: 12, battery: 7, paused: 1 };

/** Share of `stage` hidden by `win`, from 0 to 1. Both are {x, y, width, height}. */
export function coverageFraction(stage, win) {
  const area = stage.width * stage.height;
  if (!(area > 0)) return 0;
  const w = Math.min(stage.x + stage.width, win.x + win.width) - Math.max(stage.x, win.x);
  const h = Math.min(stage.y + stage.height, win.y + win.height) - Math.max(stage.y, win.y);
  if (w <= 0 || h <= 0) return 0;
  return Math.min(1, (w * h) / area);
}

export function initialState() {
  // `progress` runs 0 (stopped) to 1 (full speed) along the lock ramp.
  return { covered: false, battery: false, locked: false, progress: 1 };
}

export function reduce(state, event) {
  switch (event.type) {
    case "coverage": {
      const threshold = state.covered ? COVER_RELEASE : COVER_ENTER;
      const covered = event.fraction >= threshold;
      return covered === state.covered ? state : { ...state, covered };
    }
    case "battery":
      return { ...state, battery: Boolean(event.on) };
    case "lock":
      return { ...state, locked: Boolean(event.on) };
    case "tick": {
      const step = Math.max(0, event.seconds) / RAMP_SECONDS;
      const target = state.locked ? 0 : 1;
      const progress =
        target > state.progress
          ? Math.min(target, state.progress + step)
          : Math.max(target, state.progress - step);
      return progress === state.progress ? state : { ...state, progress };
    }
    default:
      return state;
  }
}

const ease = (t) => t * t * (3 - 2 * t);

/** What the demo shows for `state`: frame rate, power estimate, speed, status. */
export function readout(state) {
  const stoppedByLock = state.locked && state.progress === 0;
  const running = !state.covered && !stoppedByLock;
  if (!running) {
    return {
      running,
      fps: 0,
      milliwatts: MILLIWATTS.paused,
      speed: 0,
      status: state.covered ? "Paused: covered" : "Paused: locked",
    };
  }
  let status = state.battery ? "Playing on battery" : "Playing";
  if (state.locked) status = "Easing out";
  else if (state.progress < 1) status = "Easing in";
  return {
    running,
    fps: state.battery ? 30 : 60,
    milliwatts: state.battery ? MILLIWATTS.battery : MILLIWATTS.full,
    speed: ease(state.progress),
    status,
  };
}
