// Runs synchronously in <head> so the page never paints in the wrong theme.
// Kept as a classic script on purpose; the switch itself is js/theme-switch.js.
(function () {
  try {
    var choice = localStorage.getItem("lumawall-theme");
    if (choice === "light" || choice === "dark") document.documentElement.dataset.theme = choice;
  } catch (e) {}
})();
