# AGENTS.md

LumaWall plays local videos as macOS wallpapers: a Swift 6 app, a
WallpaperKit extension (`WallpaperExtension/`), and the `LumaWallCore`
SwiftPM package. The notes below cover what the code doesn't show.

## Setup

```sh
./ci/bootstrap.sh    # installs XcodeGen 2.46.0 into .tools/ (gitignored)
```

## Check and test

```sh
./ci/check.sh                          # everything CI runs, about 5-7 min
./ci/test.sh RendererLifecycleTests    # one class, in seconds
./ci/test.sh WallpaperExtensionTests/RendererLifecycleTests/testX
./ci/test.sh core                      # LumaWallCoreTests via swift test
```

`ci/test.sh` finds the target from where the class or suite is declared.
Run `./ci/check.sh` before you push.

## Lint, format and warnings

- `./ci/format.sh` formats in place with `swift format` (ships with
  Xcode; config in `.swift-format`). `./ci/check.sh` fails on any lint
  finding, so format before you commit.
- Compiler warnings are errors in every target and in `Package.swift`.
  Fix the warning; don't silence it.
- The one-time reformat is listed in `.git-blame-ignore-revs`. Run
  `git config blame.ignoreRevsFile .git-blame-ignore-revs` once to skip it
  in `git blame`.

## Xcode project

`LumaWall.xcodeproj` is generated from `project.yml`. After adding,
removing or moving a source file, run `./ci/xcodegen.sh generate` and
commit the project. CI fails if the committed project is stale. Other
XcodeGen versions write a different project, so use the pinned one.

## Danger: the live wallpaper

The owner's wallpaper runs from `/Applications/LumaWall.app`. Building
registers the built extension with macOS, and macOS can then play the
dev copy instead. So:

- Never install, open or launch a built LumaWall.app.
- Never kill or restart LumaWall, LumaWallWallpaper or WallpaperAgent.
- Don't touch `defaults` for `app.lumawall.personal` or
  `~/Library/Containers/app.lumawall.personal.wallpaper`.

`ci/check.sh` and `ci/test.sh` unregister what they built when they
exit, including on failure or Ctrl-C. After a raw `xcodebuild`, run
`./ci/unregister-builds.sh` (or `./ci/unregister-builds.sh <derived data
path>`). It runs `pluginkit -r` on the appex and `lsregister -u` on
each built `LumaWall.app`.

## CI's Xcode is older

CI builds with Xcode 26.3 on both runners (the `xcode` path per matrix
entry in `.github/workflows/wallpaper-checks.yml`); the owner's Mac has
Xcode 27. GitHub's standard runners have no Xcode 27 yet. Code that
builds locally can fail on CI, for example on region-isolation errors around `Task`
closures in `XCTestCase` methods. Watch CI after pushing.

## Where tests live

- `Tests/LumaWallCoreTests`: Swift Testing, run by `swift test`.
- `Tests/LumaWallAppTests`: XCTest, hosted by the app in the `Testing`
  configuration, which uses its own bundle id and doesn't start the real
  library.
- `Tests/WallpaperExtensionTests`: XCTest. An extension can't host a test
  bundle, so this target compiles selected extension sources directly.
  They're listed in `project.yml`; add a source there to test it.

## Media service

Media inspection and still frames (import, deploy, posters) run in
`LumaWallMediaService` (`Sources/LumaWallMediaService`, embedded in the
app's `XPCServices`), in App Sandbox with no file entitlements; the app
sends it an open read-only file handle through `MediaServiceClient`.
Route new inspection or frame extraction through `MediaProbing`, not
`AVURLAsset(url:)` in the app. Still in the app: transcoding
(`MediaImporter.exportVideoOnly`, the copy encodes, `BatteryMediaVariant`)
and `AVPlayer` playback. Testing builds gain Xcode's read-only `/`
sandbox exception, so check real entitlements on the Release build:
`codesign -d --entitlements - <Release app>/Contents/XPCServices/LumaWallMediaService.xpc`.

The service ends itself when an accepted request runs past its 110-second
deadline, and launchd starts a fresh one for a later request, about 10
seconds later (ADR 0005). The client gives up after 120 seconds but
doesn't end the service. A request sent while the service is ending or
restarting fails or times out; the client doesn't retry it.

## Extension log

`~/Library/Containers/app.lumawall.personal.wallpaper/Data/Documents/extension.log`
(rotated at 1 MB). Create a `VERBOSE_LOG` file in that `Documents`
folder for verbose logging. Read the log; don't change anything else in
that container.

## Rules

- Source files stay under 1,500 lines, tests included.
- Every maintainer or agent commit ends with exactly this trailer and no other (outside contributors sign off with a DCO `Signed-off-by` trailer per [CONTRIBUTING.md](CONTRIBUTING.md)):
  `Co-Authored-By: spade <bot@acehq.dev>`
