# 0004: Lock screen only, written per surface from one plan

## Context

Issue #109 asks for motion on the lock screen only: the video plays while
the Mac is locked, and after unlock the desktop shows the user's own
picture, or optionally a still of the video. It has to work per display,
including mixed portrait and landscape panels, and only in native mode.

Native mode writes `com.apple.wallpaper/Store/Index.plist`. Each display
has a `Desktop` surface and usually an `Idle` surface (the lock screen),
at the top level and again under each Space. Until now:

- Wallpaper assignments wrote only `Desktop` surfaces.
- The Lock Screen pick in Library wrote every `Idle` surface.
- Every write is one coordinated read-merge-write that saves a backup of
  the surfaces that aren't LumaWall's first (#82, #78), and Restore puts
  those back wherever the store shows a LumaWall surface.
- `NSWorkspace.setDesktopImageURL`, which the overlay uses for posters,
  writes an Apple image choice: provider
  `com.apple.wallpaper.choice.image`, no `Files`, and the file in a
  binary-plist `Configuration` (`type: imageFile`, `url.relative`), with
  a `Crop` placement in `EncodedOptionValues`. We saw this shape in a
  real backup on macOS 27.

## Decision

- A layout setting, `NativeSurfaceLayout`, in `UserDefaults`: preset
  `everywhere` (the old behaviour) or `lockScreenOnly`, and
  `settlesOnStill` for the second. Settings shows it under the native
  mode switch, only while native mode is on.
- `NativeSurfacePlan.changes` is a pure function from the store, the
  backup, the layout, each display's video and still, and the Lock Screen
  pick to a list of surface edits. The service runs it inside the same
  transaction as before, so nothing about locking, conflict retries or
  verification changes.
- With `lockScreenOnly`, for every copy of each display (top level and
  per Space):
  - `Idle` gets the display's own video, or the Lock Screen pick when
    there is one.
  - `Desktop` gets the video's still when `settlesOnStill` is on.
    Otherwise a desktop LumaWall had taken gets the backup's picture
    back; with no saved picture it gets the still, so it doesn't keep
    playing; a desktop that already shows the user's picture is left
    alone.
- The still is the library poster (`Poster.jpg`), the video's frame at
  time zero, written as the same Apple image choice `setDesktopImageURL`
  writes, with `Crop` placement so it fills a portrait display the way
  the video does. Writing it in the same transaction as the `Idle` change
  means one agent restart and no step where another image shows.
- `isOurs` also reads an image choice's `Configuration`, so the backup
  never saves a still (or an overlay poster) as the user's picture, and
  Restore replaces it.
- The extension health check (ADR 0003) is off with lock screen only: the
  extension draws no desktop, and the check only runs while unlocked.
- Changing the layout or the Lock Screen pick rewrites the store even when
  the wallpapers are the same.

## Alternatives considered

- Call `setDesktopImageURL` for the still after the store write. It is
  public API, but it is a second write and a second agent reload, so the
  desktop could show the old surface between the two, and it races our
  coordinated write.
- Reuse the Lock Screen playback scope (`hideDesktopVideo`), which keeps
  the extension on the desktop with a static frame. The desktop stays a
  LumaWall surface, so it can't be the user's own picture, and the
  extension stays loaded on every display.

## Consequences

- Safe mode writes nothing: the layout is only saved while native mode is
  off and applies the next time native mode writes.
- Restore undoes both `Idle` and `Desktop` edits from the backup.
- Displays the overlay plays (custom crop or spanning) aren't native, so
  their desktops keep animating under lock screen only.
- A display whose store entry has no `Idle` surface counts as unassigned
  under lock screen only and falls back to Safe mode, which plays on its
  desktop.
- The image choice format is undocumented. If macOS changes it, the still
  won't show; the checklist in `docs/testing/native-mode-matrix.md`
  covers it.
