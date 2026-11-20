# LumaWall

Play local video files as macOS wallpapers, with per-display assignments,
scheduled playlists, and playback rules for power use and Reduce Motion.

No signed, notarized download is available yet.
See [Build](#build) for setup and [Production DMG](#production-dmg) for distribution requirements.

## Requirements

- macOS 15 or newer for the overlay path
- macOS 26 or newer for the embedded WallpaperKit extension (`LumaWallWallpaper.appex`)
- Xcode with XcodeGen for the signed app target
- Swift 6 toolchain for library tests

## Product

Import MP4 or MOV. Audio is stripped. Apply to one display or all of them.

Home, Library, Displays, and Settings cover browsing, tags, favorites, recents, and playlists. Day/night and light/dark pairs switch automatically. Automations cover sunrise/sunset (approximate location), weekday masks, do-not-interrupt hours, and power-source rules. Lock screen can take the Idle poster through the native wallpaper store when the system allows it.

Shared overlay decoders reuse one player when the same media hits multiple screens. Reduce Motion freezes to a static frame. Game Mode pauses playback. On battery, a 720p variant can replace the full file. Shortcuts can apply a wallpaper. English and Spanish ship in the string catalog. Settings includes an Energy Log with a 24h sample window for soak checks.

Force overlay even on a native-capable Mac:

```sh
defaults write app.lumawall.personal lumawall.forceOverlay -bool YES
```

## How apply works

On macOS 26+ with the wallpaper extension embedded under `Contents/Extensions`, LumaWall deploys the video into the extension container and assigns it through the system wallpaper store (`com.apple.wallpaper`). WallpaperAgent hosts playback. Lock-screen live video depends on what the OS allows.

On macOS 15–25, or in SwiftPM overlay-only builds, LumaWall sets the desktop image to the poster for that screen and plays a muted looping video over it.

## Build

Install the pinned XcodeGen once, then run the checks:

```sh
./ci/bootstrap.sh                     # XcodeGen 2.46.0 into .tools/
./ci/check.sh                         # core tests, app and extension tests, Release build
./ci/test.sh RendererLifecycleTests   # one test class or suite
```

The Xcode project is generated from `project.yml`; regenerate it with
`./ci/xcodegen.sh generate`. Builds land in `.derived`. Building registers
the built wallpaper extension with macOS, which can replace a live
wallpaper from `/Applications/LumaWall.app`. The scripts unregister their
builds when they exit; after a raw `xcodebuild`, run
`./ci/unregister-builds.sh`. See [AGENTS.md](AGENTS.md) for more.

To use a build as your wallpaper, install it to `/Applications/LumaWall.app`.

## Architecture

```mermaid
flowchart TD
    App["LumaWall app"] --> Core["Library, displays, playlists and automation"]
    Core --> Policy["Power and Reduce Motion policy"]
    App -->|"macOS 26+"| Native["WallpaperKit extension and system wallpaper store"]
    App -->|"macOS 15–25 or SwiftPM"| Overlay["Poster image and muted video overlay"]
```

The native extension and overlay are alternative playback paths. Shared playback
reuses a decoder when multiple displays show the same video. Power and
accessibility rules determine when playback pauses or uses a lower-resolution file.

## Update checks

Run `./ci/check.sh` before shipping an update. It runs the core tests and the
rendered playback tests, builds the Release app, and verifies its signature.
Logs and XCTest results are saved under `.derived/checks`.

The playback tests encode temporary videos and check visible, changing frames
on multiple display layers. They cover wallpaper replacement, looping, separate
pause and resume, memory cleanup, and denied native storage access. The `Testing`
configuration uses a separate app identity and does not start the real library,
automations, or wallpaper restore.

GitHub Actions runs the same checks on macOS 15 and 26 for pull requests, changes
to `main`, and version tags. The production release script runs them before it
removes an old package or creates a new archive. A failing test stops packaging.

## Production DMG

The release script deliberately refuses development or ad-hoc identities. Configure
a Developer ID Application certificate and a `notarytool` Keychain profile, then run:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARY_KEYCHAIN_PROFILE="lumawall-notary" \
./Packaging/release.sh
```

It archives with Hardened Runtime, rejects `get-task-allow`, verifies nested code,
creates `dist/LumaWall.dmg`, submits it to Apple, staples the ticket, and requires a
passing Gatekeeper assessment. A DMG that has not completed every step is not a
production artifact.

## Author

[Luseefor](https://github.com/Luseefor).

Third-party notices for Phosphene reference code live in `THIRD_PARTY_NOTICES.md`.

## License

This project is licensed under the MIT License. See `LICENSE`.
