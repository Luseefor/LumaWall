# LumaWall

Independent macOS live-wallpaper app. Original code — not a Phosphene fork.

## What works now (0.2.0)

- Local video library with import, posters, duplicates, favorites
- Distinct Home / Explore / Library / Displays / Playlists / Settings
- Apply to main display, all displays, or a chosen display
- System desktop poster install so Space switches never flash the old wallpaper
- Live muted looping video sessions per display
- Playlist creation from favorites or the full library
- Energy profile preferences
- Menu-bar controls

## Run

Open `/Applications/LumaWall.app`, or:

```sh
swift build -c release
```

## Next

Replace the desktop video panel with a native `com.apple.wallpaper` extension so motion is owned by WallpaperAgent end-to-end.
