# 0003: The extension publishes per-display playback status in a file

## Context

The app shows, per display, whether the wallpaper plays or is paused, why, and
which copy plays at what frame rate (#108). In native mode that truth is in the
wallpaper extension: its policy, its renderer's sleep gate and the file it
reads. The app can't ask the extension, which WallpaperAgent owns, and it
doesn't have the extension's view of occlusion and power as it applies them.

## Decision

- Each extension process writes `Documents/playback-status.<pid>.json` in its
  container, with one entry per display that has an open live surface, and
  posts the Darwin notification `app.lumawall.personal.playbackStatusChanged`.
  WallpaperAgent can run a sibling process for Settings previews, so one shared
  file would be replaced by its empty snapshot; a process with nothing to report
  deletes its file. The app merges the files of live pids. The app already
  reads that folder and uses Darwin notifications both ways, so there is no new
  entitlement or channel.
- The status uses the decision `applyPolicies` last gave the renderers, not a
  second computation, and the file's frame rate is read from its track once.
- Writes happen on change only: events that can change a status (a policy
  recompute, a renderer's sleep gate, surface, file or decode failure, a
  surface added or removed) mark it dirty, a 250 ms debounce folds bursts into one write, and a
  snapshot equal to the last one isn't written. Nothing polls.
- The wire type, reasons and wording live in `DisplayPlaybackStatus.swift` in
  LumaWallCore, which the extension target compiles too, so the two sides
  can't disagree on a name. `PlaybackPolicy.decide` (extension) and
  `PlaybackPolicy.decide` (core, for the overlay) return the reason beside the
  tier; `compute` and `resolve` keep their results.
- A display takes its status from the engine drawing it: the overlay's own
  decision (Safe mode, spanning or cropped wallpapers, native fallback), or the
  extension's report.
- The app reads it like outside input: a regular file, at most 64 KB, a version
  it knows. Otherwise there's no status and the UI shows none.

## Consequences

- A display shows a status about 0.3 s after the cause changes, plus the app's
  own re-read.
- A file left by an exited process is skipped (the app checks the pid) but not
  deleted, since the app doesn't write that container.
- The reason is the first condition to reach the tier, so two causes for one
  pause show one of them.
