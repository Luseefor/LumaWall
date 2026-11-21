# 0003: The extension publishes per-display playback status in a file

## Context

The app shows, per display, whether the wallpaper plays or is paused, why, and
which copy plays at what frame rate (#108). In native mode that truth is in the
wallpaper extension: its policy, its renderer's sleep gate and the file it
reads. The app can't ask the extension, which WallpaperAgent owns, and it
doesn't have the extension's view of occlusion and power as it applies them.

## Decision

- The extension writes `Documents/playback-status.json` in its container, with
  one entry per display that has an open live surface, and posts the Darwin
  notification `app.lumawall.personal.playbackStatusChanged`. The app already
  reads that folder and uses Darwin notifications both ways, so there is no new
  entitlement or channel.
- Writes happen on change only: events that can change a status (a policy
  recompute, a renderer's sleep gate, surface or file, a surface added or
  removed) mark it dirty, a 250 ms debounce folds bursts into one write, and a
  snapshot equal to the last one isn't written. Nothing polls.
- The wire type, reasons and wording live in `DisplayPlaybackStatus.swift` in
  LumaWallCore, which the extension target compiles too, so the two sides
  can't disagree on a name. `PlaybackPolicy.decide` (extension) and
  `PlaybackPolicy.decide` (core, for the overlay) return the reason beside the
  tier; `compute` and `resolve` keep their results.
- In Safe mode (overlay) the app already knows its own decisions and records
  them directly; the file is read only in native mode.
- The app reads it like outside input: a regular file, at most 64 KB, a version
  it knows. Otherwise there's no status and the UI shows none.

## Consequences

- A display shows a status about 0.3 s after the cause changes, plus the app's
  own re-read.
- If the extension is gone, its last file stays. The row can show a stale
  state until the extension next starts and writes.
- The reason is the first condition to reach the tier, so two causes for one
  pause show one of them.
