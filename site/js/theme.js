// Runs synchronously in <head> so the page never paints in the wrong theme.
// Kept as a classic script on purpose; the switch itself is js/theme-switch.js.
(function () {
  try {
    var choice = localStorage.getItem("lumawall-theme");
    if (choice !== "light" && choice !== "dark") return;
    document.documentElement.dataset.theme = choice;
    // Match the browser toolbar colour to the chosen theme.
    var metas = document.querySelectorAll('meta[name="theme-color"][media]');
    for (var i = 0; i < metas.length; i++) {
      var meta = metas[i];
      meta.dataset.media = meta.media;
      meta.media = (/dark/.test(meta.dataset.media) ? "dark" : "light") === choice ? "all" : "not all";
    }
  } catch (e) {}
})();
