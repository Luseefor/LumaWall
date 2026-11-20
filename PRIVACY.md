# Privacy

LumaWall sends nothing off your Mac. Neither the app nor the wallpaper extension contains network client code (`URLSession`, `NWConnection`, analytics SDKs, or telemetry). Checking for updates opens the GitHub Releases page in your default browser only when you choose it.

## What stays on your Mac

- **Imported media and library metadata**: Videos you import are copied into `~/Library/Application Support/LumaWall/` (with muted variants and poster images) along with JSON files for library paths, display assignments, playlists, recents, and automation rules. When native wallpaper mode is enabled on macOS 26+, deployed copies of imported videos, poster stills, and their metadata, along with saved display IDs and covered/fullscreen state for pause rules, are stored in the extension's container (`~/Library/Containers/app.lumawall.personal.wallpaper/Data/Documents/`).
- **Preferences**: Playback, power, sort, and pause settings (including paused display IDs) are stored in local `UserDefaults` (`app.lumawall.personal`).
- **Approximate location (optional)**: If you turn on sunrise/sunset switching, LumaWall requests kilometer-accuracy location (`kCLLocationAccuracyKilometer`) from Core Location to calculate local daylight times in memory. Coordinates are not written to disk or transmitted anywhere.
- **On-screen window geometry**: To pause playback when another app covers a display, LumaWall reads on-screen window bounds, window layers, alpha values, and owning process activation policies via `CGWindowListCopyWindowInfo`. It does not read window titles, window contents, or screen pixels, and does not require Screen Recording permission.
- **Local diagnostic logs**: Crash reports (`*.crash.json`) and 24-hour energy soak samples (`EnergyLog.json`) are saved locally under `~/Library/Application Support/LumaWall/`. In native mode, LumaWall writes local macOS unified-log (`Logger`) entries containing wallpaper names and display IDs, and the wallpaper extension writes a rotating local log (`~/Library/Containers/app.lumawall.personal.wallpaper/Data/Documents/extension.log`, rotated at 1 MB with two rotated backup copies). These logs never leave your Mac unless you copy and share them yourself.

## Deleting local data

If you used native wallpaper mode, first use **Restore original wallpaper** in LumaWall (or switch to a standard macOS wallpaper in System Settings) before deleting LumaWall's folders; otherwise macOS may still reference the deployed media in the extension container and deleting `~/Library/Application Support/LumaWall/` removes LumaWall's backup of your previous wallpaper settings.

Then quit LumaWall and remove:

- `~/Library/Application Support/LumaWall/`
- `~/Library/Containers/app.lumawall.personal.wallpaper/`
- `~/Library/Preferences/app.lumawall.personal.plist`
