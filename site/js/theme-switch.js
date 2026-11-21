import { THEME_KEY, attributeFor, normalizeChoice } from "./theme-model.js";

function read() {
  try {
    return normalizeChoice(localStorage.getItem(THEME_KEY));
  } catch {
    return "system";
  }
}

function apply(choice) {
  const root = document.documentElement;
  const value = attributeFor(choice);
  if (value) root.dataset.theme = value;
  else delete root.dataset.theme;
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
