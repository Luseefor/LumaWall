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

```sh
cd LumaWall
swift build -c release
swift test
```

The installed app path used in this project is `/Applications/LumaWall.app`.

## How apply works today

1. Set the system desktop image to the wallpaper poster for that screen.
2. Play a muted looping video over that screen.

A native `com.apple.wallpaper` extension is the next engine step.

## Author

Commits and package metadata use **Luseefor** (`sapanakosansar18@gmail.com`). Do not attribute work to cursor-agent or other tool identities.
