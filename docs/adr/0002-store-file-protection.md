# 0002: Store files readable after first unlock

## Context

LumaWall keeps its library, settings, schedules and logs as JSON files in
Application Support. They were written with `completeFileProtectionUnlessOpen`.
With that class, an existing file can't be opened while the screen is locked.

LumaWall keeps working while the Mac is locked: day/night schedules fire,
lock-screen playback runs, and the energy log loads after a relaunch. A load
while locked came back empty. A clean build on a second Mac, left locked,
failed two energy-log tests for this reason.

## Decision

Write store files with `completeFileProtectionUntilFirstUserAuthentication`.
They stay encrypted from boot until the first unlock, then remain readable
while the screen is locked. A successful read rewrites a file that still has
the older class, so existing installs move over without a migration step.

## Consequences

- Loads behave the same locked or unlocked, so schedules and lock-screen
  playback see the real library and settings.
- After the first unlock, a process running as the user can read the files
  while the screen is locked. These files hold wallpaper choices, schedules
  and logs, not secrets, so this is the usual class for background app data.
- Before the first unlock after boot the files stay unreadable, as before.
