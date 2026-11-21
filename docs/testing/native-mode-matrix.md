# Native mode test matrix

Run on real Macs with native mode on (Settings → Wallpaper host). Run the
whole list once on macOS 26 and once on macOS 27. The app can't be tested
in a simulator or by CI.

Before each run:

- Note the Mac model, macOS build (`sw_vers`) and LumaWall version.
- Use at least two displays where a row asks for it, one of them able to
  rotate to portrait.
- Give each display a different LumaWall wallpaper.
- Keep `extension.log` open
  (`~/Library/Containers/app.lumawall.personal.wallpaper/Data/Documents/extension.log`)
  and Console filtered to subsystem `app.lumawall.personal`, category
  `native-host`.

A pass means: the wallpaper plays on every display afterwards, no display
falls back to Safe mode, and no failure notice appears. The extension health
check waits 30 seconds after each of these events (ADR 0003), so wait at
least 45 seconds before recording a row.

Fill in Observed with what you saw, and Result with pass or fail. Put log
lines for failures under Notes.

## macOS 26

Mac: ______ · Build: ______ · LumaWall: ______ · Date: ______

| # | Check | Expected | Observed | Result |
|---|-------|----------|----------|--------|
| 1 | Update macOS (minor update), log in | Wallpapers play on every display within a minute; no notice. If native mode broke, each affected display shows the notice once and plays in Safe mode | | |
| 2 | Lock and unlock 20 times, about 5 s locked each | Plays after every unlock; no notice; no Safe mode fallback | | |
| 3 | Lock for 2 minutes, unlock | Plays after unlock; no notice | | |
| 4 | Sleep the Mac (Apple menu → Sleep), wake after 1 minute | Plays after wake; no notice | | |
| 5 | Sleep overnight or for 30+ minutes, wake | Plays after wake; no notice | | |
| 6 | Let the displays sleep (Energy settings), wake them | Plays after wake; no notice | | |
| 7 | Disconnect an external display, wait 1 minute, reconnect | Its wallpaper comes back; the other display keeps playing; no notice | | |
| 8 | Reconnect it on a different port or dock | Same as 7 | | |
| 9 | Rotate the external display to portrait | Wallpaper fills the portrait display; no notice | | |
| 10 | Rotate back to landscape | Wallpaper fills the display; no notice | | |
| 11 | Close and open the lid with an external display (clamshell) | Plays on the remaining displays; no notice | | |
| 12 | Switch Spaces 20 times (Control-arrow) on each display | Plays on every Space; no notice | | |
| 12a | Set an Apple wallpaper on one Space in System Settings, stay on that Space 2 minutes, switch back | No notice; the LumaWall Space still plays natively |
| 13 | Enter and leave a full-screen app | Pauses in full screen, plays after; no notice | | |
| 14 | Mission Control in and out | Plays; no notice | | |
| 15 | Start the screen saver (hot corner), stop it after 1 minute | Plays after; no notice | | |
| 16 | Screen saver until the screen locks, then unlock | Plays after unlock; no notice | | |
| 17 | Forced failure, on a test Mac only: once `native-host` logs show no health errors for a minute, quit LumaWallWallpaper in Activity Monitor and watch for 60 s | If macOS restarts it, wallpapers come back and no notice. If not, within about 35 s each display shows the notice once (macOS notification and banner, naming the display) and plays in Safe mode | | |
| 18 | Restore from the notice: click Restore Original Wallpaper in the macOS notification | Native mode turns off; LumaWall stops playing; your previous wallpaper is back; a message says so | | |
| 19 | Restore from the menu bar: open the popover, click the restore button (↩) | Same as 18, in two clicks | | |
| 20 | Restore from Settings → Wallpaper host → Restore | Same as 18 | | |

Notes:

## macOS 27

Mac: ______ · Build: ______ · LumaWall: ______ · Date: ______

| # | Check | Expected | Observed | Result |
|---|-------|----------|----------|--------|
| 1 | Update macOS (minor update), log in | Wallpapers play on every display within a minute; no notice. If native mode broke, each affected display shows the notice once and plays in Safe mode | | |
| 2 | Lock and unlock 20 times, about 5 s locked each | Plays after every unlock; no notice; no Safe mode fallback | | |
| 3 | Lock for 2 minutes, unlock | Plays after unlock; no notice | | |
| 4 | Sleep the Mac (Apple menu → Sleep), wake after 1 minute | Plays after wake; no notice | | |
| 5 | Sleep overnight or for 30+ minutes, wake | Plays after wake; no notice | | |
| 6 | Let the displays sleep (Energy settings), wake them | Plays after wake; no notice | | |
| 7 | Disconnect an external display, wait 1 minute, reconnect | Its wallpaper comes back; the other display keeps playing; no notice | | |
| 8 | Reconnect it on a different port or dock | Same as 7 | | |
| 9 | Rotate the external display to portrait | Wallpaper fills the portrait display; no notice | | |
| 10 | Rotate back to landscape | Wallpaper fills the display; no notice | | |
| 11 | Close and open the lid with an external display (clamshell) | Plays on the remaining displays; no notice | | |
| 12 | Switch Spaces 20 times (Control-arrow) on each display | Plays on every Space; no notice | | |
| 12a | Set an Apple wallpaper on one Space in System Settings, stay on that Space 2 minutes, switch back | No notice; the LumaWall Space still plays natively |
| 13 | Enter and leave a full-screen app | Pauses in full screen, plays after; no notice | | |
| 14 | Mission Control in and out | Plays; no notice | | |
| 15 | Start the screen saver (hot corner), stop it after 1 minute | Plays after; no notice | | |
| 16 | Screen saver until the screen locks, then unlock | Plays after unlock; no notice | | |
| 17 | Forced failure, on a test Mac only: once `native-host` logs show no health errors for a minute, quit LumaWallWallpaper in Activity Monitor and watch for 60 s | If macOS restarts it, wallpapers come back and no notice. If not, within about 35 s each display shows the notice once (macOS notification and banner, naming the display) and plays in Safe mode | | |
| 18 | Restore from the notice: click Restore Original Wallpaper in the macOS notification | Native mode turns off; LumaWall stops playing; your previous wallpaper is back; a message says so | | |
| 19 | Restore from the menu bar: open the popover, click the restore button (↩) | Same as 18, in two clicks | | |
| 20 | Restore from Settings → Wallpaper host → Restore | Same as 18 | | |

Notes:

## Lock screen only (issue #109)

Run on macOS 26 and 27 with a landscape laptop panel plus one landscape
and one portrait external display, each with a different LumaWall
wallpaper. Before starting, set a different picture of your own on each
display in System Settings → Wallpaper, then turn native mode on.

| # | Check | Expected | Observed | Result |
|---|-------|----------|----------|--------|
| L1 | Settings → Wallpaper host → Play the video on → Lock screen only. Lock | Each lock screen plays its own display's video, portrait included | | |
| L2 | Unlock | Each desktop shows the picture you chose before, with no frame of video or other image in between; no notice | | |
| L3 | Lock and unlock 10 times | Same as L1 and L2 every time; no Safe mode fallback | | |
| L4 | Desktop after unlock → Still of the video. Unlock after locking | Each desktop shows the first frame of its own video, filling the portrait display; no flash of your picture or black | | |
| L5 | Rotate the portrait display to landscape and back | The still and the lock screen video fill it each way | | |
| L6 | Disconnect and reconnect an external display | Its lock screen video and desktop picture or still come back | | |
| L7 | Pick a Lock Screen wallpaper in Library | Every lock screen plays that one; desktops unchanged | | |
| L8 | Clear the Lock Screen pick | Each lock screen goes back to its display's own video | | |
| L9 | Play the video on → Desktop | Desktops play again; lock screens keep the video | | |
| L10 | Lock screen only, then turn native mode off | Nothing in the store changes; Safe mode plays on the desktops | | |
| L11 | With lock screen only and the still on, Settings → Restore | Desktops and lock screens show your own pictures again; a message says so | | |

Notes:
