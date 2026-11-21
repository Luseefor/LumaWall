const MOBILE = matchMedia("(max-width: 860px)");

/** Which tone the bar should wear over whatever sits under it. */
export function toneAt(y, darkRanges) {
  return darkRanges.some(({ top, bottom }) => y >= top && y < bottom) ? "dark" : "light";
}

/**
 * Where focus should go when the window crosses the menu breakpoint, so it is
 * never left on something that just stopped being shown. `active` is where it
 * is now: "menu" (a link or the theme switch in the list), "toggle" or "other".
 */
export function focusAfterBreakpoint({ mobile, active }) {
  if (mobile && active === "menu") return "toggle"; // the list is about to be hidden
  if (!mobile && active === "toggle") return "menu"; // the button is about to disappear
  return null;
}

/** The mobile menu: a button that opens the section links as a dropdown. */
function setUpMenu(header) {
  const nav = header.querySelector("[data-nav]");
  const toggle = header.querySelector("[data-nav-toggle]");
  const menu = header.querySelector("[data-nav-menu]");
  if (!nav || !toggle || !menu) return;

  header.classList.add("nav-js");
  toggle.hidden = false;

  const items = () => [...nav.querySelectorAll("a, button")].filter((el) => !el.closest("[hidden]"));
  const isOpen = () => toggle.getAttribute("aria-expanded") === "true";

  function set(open, { restoreFocus = false } = {}) {
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close menu" : "Menu");
    menu.hidden = !open && MOBILE.matches;
    if (open) document.addEventListener("pointerdown", outside, true);
    else document.removeEventListener("pointerdown", outside, true);
    if (open) menu.querySelector("a")?.focus();
    if (!open && restoreFocus) toggle.focus();
  }

  function outside(event) {
    if (!nav.contains(event.target)) set(false);
  }

  toggle.addEventListener("click", () => set(!isOpen()));
  menu.addEventListener("click", (event) => {
    if (event.target.closest("a")) set(false);
  });

  header.addEventListener("keydown", (event) => {
    if (!isOpen()) return;
    if (event.key === "Escape") {
      event.preventDefault();
      set(false, { restoreFocus: true });
      return;
    }
    if (event.key !== "Tab") return;
    // Keep Tab inside the bar while the menu is open.
    const stops = items();
    const first = stops[0];
    const last = stops.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  const sync = () => {
    const active = menu.contains(document.activeElement) ? "menu" : document.activeElement === toggle ? "toggle" : "other";
    const move = focusAfterBreakpoint({ mobile: MOBILE.matches, active });
    // Wide screens show the links in the bar; narrow ones hide them until asked.
    if (!MOBILE.matches) set(false);
    else menu.hidden = !isOpen();
    // Hand focus over once the layout has changed, but only if it would otherwise be dropped.
    if (move === "toggle" && !isOpen()) toggle.focus();
    else if (move === "menu") menu.querySelector("a")?.focus();
  };
  MOBILE.addEventListener("change", sync);
  sync();
}

/** Switch the bar to its dark variant while a dark section is under it. */
function setUpTone(header) {
  const darks = [...document.querySelectorAll("section.dark")];
  if (!darks.length) return;
  let ranges = [];
  let frame = 0;

  const measure = () => {
    ranges = darks.map((el) => {
      const rect = el.getBoundingClientRect();
      return { top: rect.top + scrollY, bottom: rect.bottom + scrollY };
    });
  };
  const apply = () => {
    frame = 0;
    // Sample the middle of the bar.
    header.dataset.tone = toneAt(scrollY + header.offsetHeight / 2, ranges);
  };
  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(apply);
  };

  measure();
  apply();
  addEventListener("scroll", schedule, { passive: true });
  addEventListener("resize", () => {
    measure();
    schedule();
  });
  // Late layout changes (images, fonts, revealed sections) move the sections.
  new ResizeObserver(() => {
    measure();
    schedule();
  }).observe(document.body);
}

export function setUpNav() {
  const header = document.querySelector(".nav");
  if (!header) return;
  setUpMenu(header);
  setUpTone(header);
}
