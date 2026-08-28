# LumaWall

Live video wallpapers on macOS, from files already on your disk. Bundle id `app.lumawall.personal`. Version 0.4.0 (build 12).

This is the production cut of the app: import, assign, automate, pause for power and accessibility, then leave it alone. Distribution still needs a Developer ID signature, notarization, and a DMG or Homebrew package before Gatekeeper-clean installs for other people. Until then, build and install locally.

## Requirements

- macOS 15 or newer for the overlay path
- macOS 26 or newer for the embedded WallpaperKit extension (`LumaWallWallpaper.appex`)
- Xcode with XcodeGen for the signed app target
- Swift 6 toolchain for library tests

## Product

Import MP4 or MOV. Audio is stripped. Apply to one display or all of them.

Home, Library, Displays, and Settings cover browsing, tags, favorites, recents, playlists, and day/night or light/dark pairs. Automations cover sunrise/sunset (approximate location), weekday masks, do-not-interrupt hours, and power-source rules. Lock screen can take the Idle poster through the native wallpaper store when the system allows it.

Shared overlay decoders reuse one player when the same media hits multiple screens. Reduce Motion freezes to a static frame. Game Mode pauses playback. On battery, a 720p variant can replace the full file. Shortcuts can apply a wallpaper. English and Spanish ship in the string catalog. Settings includes an Energy Log with a 24h sample window for soak checks.

Force overlay even on a native-capable Mac:

```sh
defaults write app.lumawall.personal lumawall.forceOverlay -bool YES
```

## How apply works

On macOS 26+ with the wallpaper extension embedded under `Contents/Extensions`, LumaWall deploys the video into the extension container and assigns it through the system wallpaper store (`com.apple.wallpaper`). WallpaperAgent hosts playback. Lock-screen live video depends on what the OS allows that day.

On macOS 15–25, or in SwiftPM overlay-only builds, LumaWall sets the desktop image to the poster for that screen and plays a muted looping video over it.

## Build

Library and overlay tests (macOS 15+):

```sh
cd LumaWall
swift build -c release
swift test
```

Native host with the wallpaper appex (macOS 26+):

```sh
cd LumaWall
xcodegen generate
xcodebuild -scheme LumaWall -configuration Release -derivedDataPath .derived build
```

Install the built app to `/Applications/LumaWall.app` for the path this project expects.

## Release checklist

Still open for a public binary:

1. Sign with Developer ID Application and enable Hardened Runtime (already on in `project.yml`).
2. Notarize and staple.
3. Ship a DMG or Homebrew cask, plus an updater if you want in-app updates.
4. Attach crash reporting before a wide release.

Local production use does not need those steps. Third-party installs do.

## Author

Luseefor (`sapanakosansar18@gmail.com`). Commits and package metadata use that identity. Do not attribute this work to cursor-agent or other tool accounts.

Third-party notices for Phosphene reference code live in `THIRD_PARTY_NOTICES.md`.

## License

This project is licensed under the MIT License. See `LICENSE`.
