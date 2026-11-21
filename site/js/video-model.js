/** Whether an autoplaying wallpaper clip should be running right now. */
export const shouldPlay = ({ inView, hidden, reduced, paused }) => inView && !hidden && !reduced && !paused;

/**
 * Whether a gallery card plays: on hover, or after an explicit tap. Data Saver
 * ignores hover (it would download a clip nobody asked for) but a tap is an
 * explicit request, so it always plays.
 */
export const cardPlays = ({ inView, hidden, reduced, hovered, toggled, saveData = false }) =>
  inView && !hidden && (toggled || (hovered && !reduced && !saveData));

/** The next layer of a cycle, wrapping around. */
export const nextIndex = (index, count) => (index + 1) % count;

const SECONDS_AHEAD = 4;

/**
 * Whether a clip can be faded in without stalling on a frame-less layer (which
 * would uncover the poster underneath): the browser says it can play through,
 * or enough of it is buffered.
 */
export const canCrossfade = ({ readyState, bufferedAhead = 0, duration = 0 }) =>
  readyState >= 4 || (readyState >= 3 && bufferedAhead >= Math.min(SECONDS_AHEAD, duration || SECONDS_AHEAD));

/** The seconds buffered past the current position. */
export function bufferedAhead(video) {
  const { buffered, currentTime } = video;
  for (let i = 0; i < buffered.length; i++) {
    if (currentTime >= buffered.start(i) && currentTime <= buffered.end(i)) return buffered.end(i) - currentTime;
  }
  return 0;
}

export const SMALL_WIDTH = 960;
const PHONE_VIEWPORT = 860;

/**
 * The clip files to offer, best first. Phones and anything drawn small get the
 * 960 px copy; the original file is always the fallback, so a missing copy
 * costs one failed request and nothing else.
 */
export function clipSources(src, { elementWidth = 0, viewportWidth = Infinity, dpr = 1 } = {}) {
  const small = src.replace(/\.mp4$/, `-${SMALL_WIDTH}.mp4`);
  if (small === src) return [{ src }];
  const phone = viewportWidth <= PHONE_VIEWPORT;
  const drawnSmall = elementWidth > 0 && elementWidth * dpr <= SMALL_WIDTH * 1.05;
  if (phone) return [{ src: small, media: `(max-width: ${PHONE_VIEWPORT}px)` }, { src }];
  if (drawnSmall) return [{ src: small }, { src }];
  return [{ src }];
}
