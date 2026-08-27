# LumaWall

macOS app for live video wallpapers from files on your Mac.

## What it does

- Import MP4 or MOV files (audio is stripped)
- Apply to one display or every display
- Browse Home, Library, Displays, and Settings
- Tag with categories, favorites, and recents
- Rotate playlists from Library
- Day/night and light/dark wallpaper pairs from Library
- Pause per display or globally, set energy profile, clear cache, launch at login

Version is in `Packaging/Info.plist`.

## Build and run

Overlay / library tests (macOS 15+):

```sh
cd LumaWall
swift build -c release
swift test
```

Native wallpaper host (macOS 26+, embeds `LumaWallWallpaper.appex`):

```sh
cd LumaWall
xcodegen generate
xcodebuild -scheme LumaWall -configuration Release -derivedDataPath .derived build
```

The installed app path used in this project is `/Applications/LumaWall.app`.

## How apply works

**macOS 26+ with the wallpaper extension embedded**

1. Deploy the video into the extension container.
2. Assign it through the system wallpaper store (`com.apple.wallpaper` provider).
3. WallpaperAgent hosts playback; lock-screen live video is available when the system allows it.

**macOS 15–25, or SwiftPM / overlay-only builds**

1. Set the system desktop image to the wallpaper poster for that screen.
2. Play a muted looping video over that screen.

Force overlay on a native-capable Mac with `defaults write app.lumawall.personal lumawall.forceOverlay -bool YES`.

## Author

Commits and package metadata use **Luseefor** (`sapanakosansar18@gmail.com`). Do not attribute work to cursor-agent or other tool identities.
