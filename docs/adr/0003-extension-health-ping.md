# 0003: Check the wallpaper extension with a ping and an answer file

## Context

In native mode the macOS wallpaper agent runs LumaWall's extension, and the
app only writes the wallpaper store. If the extension crashes and isn't
relaunched, or the agent stops asking it for a display, the app can't see it:
the display shows whatever macOS falls back to. Issue #107 asks for the app to
notice within about 20 seconds and move that display to Safe mode.

What the two sides share today:

- `lumawall-prefs.json` in the extension's Documents folder, written by the
  app, with a `prefsChanged` Darwin notification.
- `lumawall-state.json`, written by the extension when it gains a surface or
  changes video. Nothing in the app reads it, and it isn't rewritten when a
  surface goes away.
- Darwin notifications both ways (`libraryChanged`, `clearCaches`,
  `agentStuck`).
- `extension.log`, which is for people, rotates, and may be verbose or not.

The extension has no timer of its own and may idle while paused. It does
answer Darwin notifications whenever playback could resume, because that is
how `prefsChanged` reaches it. While the screen is locked, the displays sleep
or the screen saver runs, it may be suspended, and macOS may drop and
re-acquire its surfaces around wake, unlock, display changes, Space switches
and every WallpaperAgent restart the app causes by writing the store.

## Decision

- The app posts `app.lumawall.personal.healthPing`. The extension answers by
  writing `lumawall-health.json` (`pid`, an in-memory `sequence` that goes up
  on every answer, and the CoreGraphics IDs of displays it holds a surface
  for, previews included, since a preview surface can be handed to the
  desktop). Answers are throttled to one a second.
- The app reads the file before the ping and 3 seconds after. A changed
  `pid` or `sequence` is a fresh answer. A display the app plays natively that
  is missing from fresh answers, or from all answers once the extension
  stopped answering, for 20 seconds falls back to Safe mode and the user is
  told.
- Probes run every 10 seconds, every 4 while a display is missing, and only
  while native mode plays something, the session is unlocked, the displays are
  awake and the screen saver isn't running. Displays that are asleep on their
  own or mirror another display aren't watched.
- Launch, wake, unlock, a display change, a Space switch, the screen saver
  ending, the session becoming unlocked or awake, and any store write by the
  app start a 30-second grace period and clear earlier misses. A verdict is
  dropped if the store was written between the probe and the fallback.
- A display that some Space shows a non-LumaWall wallpaper on isn't fallen
  back: the extension doesn't run there, so a miss proves nothing. The store
  is read only when a display is about to fall back; if it can't be read,
  nothing falls back.
- Silence alone counts only once this app build's extension has answered,
  this session or an earlier one (remembered in user defaults by build
  number). An extension that never answered is likely an older build still
  running after an update. A fresh answer that leaves a display out always
  counts.
- Displays that fall back are released from the native engine, and native
  work already running doesn't write them back to the store.
- The rules live in `ExtensionHealth` (LumaWallCore), a pure type with tests.

## Alternatives considered

- A heartbeat timer in the extension writing every few seconds. It wakes the
  extension all day, and goes quiet whenever the extension is legitimately
  suspended, which is exactly when it must not trigger.
- Reading `lumawall-state.json`. It isn't updated when a surface goes away
  and has no way to tell a fresh write from an old one.
- Parsing `extension.log`. It's free text for people and rotates.
- A wall-clock timestamp in the answer. A clock change could make a fresh
  answer look old. `pid` plus `sequence` doesn't depend on the clock.
- Passing a nonce with the ping (`notify_set_state` or a request file). Any
  local process can post Darwin notifications, and a spoofed ping only makes
  the extension answer truthfully one more time, so a nonce adds nothing.

## Consequences

- One Darwin notification, one small file write in the extension and two
  small reads in the app every 10 seconds while native mode is visible.
  Nothing runs while the Mac is locked, asleep or showing the screen saver.
- A failure is noticed 20 to about 35 seconds after it starts.
- A display with a non-LumaWall wallpaper on any Space isn't covered by the
  check until that Space shows LumaWall again.
- On the first launch of a new build, an extension that is already broken
  and never answers isn't caught by the ping. Assignment and verification
  failures still are.
- The live checks are in `docs/testing/native-mode-matrix.md`.
