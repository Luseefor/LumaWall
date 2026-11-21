import { THEME_KEY, attributeFor, normalizeChoice } from "./theme-model.js";

function read() {
  try {
    return normalizeChoice(localStorage.getItem(THEME_KEY));
  } catch {
    return "system";
  }
}

/** Keep the browser toolbar colour in step with a chosen theme (the tags carry a media query for the system's). */
function syncToolbar(value) {
  for (const meta of document.querySelectorAll('meta[name="theme-color"][media]')) {
    meta.dataset.media ??= meta.media;
    const scheme = /dark/.test(meta.dataset.media) ? "dark" : "light";
    meta.media = value ? (scheme === value ? "all" : "not all") : meta.dataset.media;
  }
}

function apply(choice) {
  const root = document.documentElement;
  const value = attributeFor(choice);
  if (value) root.dataset.theme = value;
  else delete root.dataset.theme;
  syncToolbar(value);
}

/** The System / Light / Dark control in the nav. Hidden until scripting can make it work. */
export function setUpThemeSwitch() {
  const group = document.querySelector("[data-theme-switch]");
  if (!group) return;
  const buttons = [...group.querySelectorAll("button[data-choice]")];
  const show = (choice) => {
    for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.choice === choice));
  };
  let choice = read();
  apply(choice);
  show(choice);
  group.closest("[hidden]")?.removeAttribute("hidden");

  for (const button of buttons) {
    button.addEventListener("click", () => {
      choice = normalizeChoice(button.dataset.choice);
      apply(choice);
      show(choice);
      try {
        if (choice === "system") localStorage.removeItem(THEME_KEY);
        else localStorage.setItem(THEME_KEY, choice);
      } catch {}
    });
  }
  // Another tab changed it.
  addEventListener("storage", (event) => {
    if (event.key !== THEME_KEY) return;
    choice = normalizeChoice(event.newValue);
    apply(choice);
    show(choice);
  });
}
