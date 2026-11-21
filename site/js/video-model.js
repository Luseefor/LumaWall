/** Whether an autoplaying wallpaper clip should be running right now. */
export const shouldPlay = ({ inView, hidden, reduced, paused }) => inView && !hidden && !reduced && !paused;

/** Whether a gallery card plays: on hover, or after an explicit tap. */
export const cardPlays = ({ inView, hidden, reduced, hovered, toggled }) =>
  inView && !hidden && (toggled || (hovered && !reduced));

/** The next layer of a cycle, wrapping around. */
export const nextIndex = (index, count) => (index + 1) % count;
