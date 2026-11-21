# 0002: Store files use "until first user authentication"

## Context

LumaWall keeps its library, settings, schedules and logs as JSON files in
Application Support, written by `StoreIO`. They used the
`completeFileProtectionUnlessOpen` data-protection class.

LumaWall keeps working while the Mac is locked: schedules fire, lock-screen
playback runs, and stores load after a relaunch. On two Macs, opening an
existing store file failed while the screen was locked and worked once it was
unlocked: the energy-log tests failed only on the locked machine. A failed
open loaded as an empty store, and the next save would have replaced the real
file with that empty state.

## Decision

- Write store files with `completeFileProtectionUntilFirstUserAuthentication`
  (Apple's Class C). Apple documents this class as protected from boot until
  the user first authenticates, then available until restart; it is the usual
  class for data a background app reads.
- When a store with an older class is read, change its class in place on the
  open file (`F_SETPROTECTIONCLASS` on an `O_NOFOLLOW` descriptor). Nothing is
  rewritten, so a second running instance's newer save can't be replaced with
  stale bytes, and a symlink is never followed.
- `StoreIO.writeJSON` refuses to replace a store that exists but can't be
  opened for reading. Its owner loaded it as empty, so saving would erase it.

## Consequences

- Loads behave the same whether the screen is locked or not.
- After the first unlock, a process running as the user can read these files
  while the screen is locked. They hold wallpaper choices, schedules and logs,
  not credentials.
- If a store is unreadable when its owner loads it, saves fail until relaunch
  instead of erasing it. A store that loaded empty that way and then becomes
  readable could still be overwritten by its next save; with the new class
  this needs the app to start before the first unlock, which a login item
  doesn't.
