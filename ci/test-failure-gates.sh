#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/ci" "$fixture_dir/Packaging" "$fixture_dir/bin" "$fixture_dir/dist"
cp "$project_root/ci/check.sh" "$fixture_dir/ci/check.sh"
cp "$project_root/ci/unregister-builds.sh" "$fixture_dir/ci/unregister-builds.sh"
cp "$project_root/ci/test.sh" "$fixture_dir/ci/test.sh"
cp "$project_root/ci/xcodegen.sh" "$fixture_dir/ci/xcodegen.sh"
cp "$project_root/Packaging/release.sh" "$fixture_dir/Packaging/release.sh"
# Avoid recursively running this fixture test inside the copied validator.
printf '#!/bin/bash\nexit 0\n' > "$fixture_dir/ci/test-failure-gates.sh"
export PATH="$fixture_dir/bin:$PATH"
export LUMAWALL_CHECK_OUTPUT_DIR="$fixture_dir/results"
export LUMAWALL_GATE_MARKERS="$fixture_dir"
export LUMAWALL_LSREGISTER="$fixture_dir/bin/lsregister"
# A previous build's app, which check.sh must unregister however it exits.
built_app="$fixture_dir/.derived/Build/Products/Testing/LumaWall.app"
mkdir -p "$built_app/Contents/Extensions/LumaWallWallpaper.appex"

cat > "$fixture_dir/bin/swift" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/swift.log"
# Interrupt the whole check, as Ctrl-C in a terminal would.
[[ "${LUMAWALL_FAKE_SWIFT_EXIT:-}" == interrupt ]] && { kill -INT "$PPID"; kill -INT $$; }
exit "${LUMAWALL_FAKE_SWIFT_EXIT:-0}"
SH
cat > "$fixture_dir/bin/xcodegen" <<'SH'
#!/bin/bash
[[ "$1" == --version ]] && { printf 'Version: %s\n' "${LUMAWALL_FAKE_XCODEGEN_VERSION:-2.46.0}"; exit 0; }
touch "$LUMAWALL_GATE_MARKERS/generated"
SH
cat > "$fixture_dir/bin/xcodebuild" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/xcodebuild.log"
case " $* " in
  *" test "*) exit 44 ;;
  *) touch "$LUMAWALL_GATE_MARKERS/packaged"; exit 99 ;;
esac
SH
cat > "$fixture_dir/bin/security" <<'SH'
#!/bin/bash
printf 'Developer ID Application: Release Gate Fixture\n'
SH
cat > "$fixture_dir/bin/pluginkit" <<'SH'
#!/bin/bash
printf 'pluginkit %s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/unregistered"
SH
cat > "$fixture_dir/bin/lsregister" <<'SH'
#!/bin/bash
printf 'lsregister %s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/unregistered"
SH
chmod +x "$fixture_dir/bin/"* "$fixture_dir/ci/"*.sh

# /bin/bash 3.2 doesn't exit on a failed [[ ]] under set -e, so every
# check states its own failure.
fail() {
    printf 'Failure gate check failed: %s\n' "$1" >&2
    exit 1
}

expect_unregistered() {
    grep -Fqx "pluginkit -r $built_app/Contents/Extensions/LumaWallWallpaper.appex" "$fixture_dir/unregistered"
    grep -Fqx "lsregister -u $built_app" "$fixture_dir/unregistered"
    rm "$fixture_dir/unregistered"
}

expect_exit() {
    local expected="$1"
    shift
    local actual=0
    "$@" > "$fixture_dir/command.log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$fixture_dir/command.log" >&2
        printf 'Expected exit %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

# A core-test failure must stop before building the app.
LUMAWALL_FAKE_SWIFT_EXIT=43 expect_exit 43 bash "$fixture_dir/ci/check.sh"
[[ ! -e "$fixture_dir/generated" ]] || fail "line $LINENO"
expect_unregistered

# A playback failure must stop before compiling a release.
expect_exit 44 bash "$fixture_dir/ci/check.sh"
[[ -e "$fixture_dir/generated" && ! -e "$fixture_dir/packaged" ]] || fail "line $LINENO"
expect_unregistered

# An interrupted run must still unregister the built app.
LUMAWALL_FAKE_SWIFT_EXIT=interrupt expect_exit 130 bash "$fixture_dir/ci/check.sh"
expect_unregistered

# ci/test.sh runs a core suite with swift test only.
mkdir -p "$fixture_dir/Tests/LumaWallCoreTests" "$fixture_dir/Tests/WallpaperExtensionTests" \
    "$fixture_dir/LumaWall.xcodeproj"
printf '@Suite struct PowerPolicyTests {}\n' > "$fixture_dir/Tests/LumaWallCoreTests/PowerPolicyTests.swift"
printf 'final class RendererLifecycleTests: XCTestCase {}\n' \
    > "$fixture_dir/Tests/WallpaperExtensionTests/RendererLifecycleTests.swift"
printf 'targets: {}\n' > "$fixture_dir/project.yml"
printf '/* RendererLifecycleTests.swift */\n' > "$fixture_dir/LumaWall.xcodeproj/project.pbxproj"
# Fixed times: -nt only compares whole seconds in /bin/bash 3.2.
touch -t 202001010000 "$fixture_dir/project.yml"
touch -t 202101010000 "$fixture_dir/LumaWall.xcodeproj/project.pbxproj"
rm -f "$fixture_dir/swift.log" "$fixture_dir/xcodebuild.log" "$fixture_dir/generated"
expect_exit 0 bash "$fixture_dir/ci/test.sh" PowerPolicyTests/testBattery
grep -Fqx 'test --filter LumaWallCoreTests\.PowerPolicyTests/testBattery' "$fixture_dir/swift.log"
[[ ! -e "$fixture_dir/xcodebuild.log" ]] || fail "line $LINENO"

# ci/test.sh runs an extension test class with -only-testing, keeps the
# xcodebuild failure, skips xcodegen while the project is current, and
# unregisters the built app.
expect_exit 44 bash "$fixture_dir/ci/test.sh" RendererLifecycleTests/testStop
grep -Fq ' -configuration Testing ' "$fixture_dir/xcodebuild.log"
grep -Fq ' -only-testing:WallpaperExtensionTests/RendererLifecycleTests/testStop ' "$fixture_dir/xcodebuild.log"
[[ ! -e "$fixture_dir/generated" ]] || fail "line $LINENO"
expect_unregistered

# ci/test.sh regenerates the project once project.yml is newer.
touch -t 202201010000 "$fixture_dir/project.yml"
expect_exit 44 bash "$fixture_dir/ci/test.sh" WallpaperExtensionTests/RendererLifecycleTests
[[ -e "$fixture_dir/generated" ]] || fail "line $LINENO"
expect_unregistered

# ci/test.sh regenerates the project for a test file it doesn't list yet,
# also when the name starts with its target.
touch -t 202001010000 "$fixture_dir/project.yml"
rm "$fixture_dir/generated"
printf 'final class NewTests: XCTestCase {}\n' > "$fixture_dir/Tests/WallpaperExtensionTests/NewTests.swift"
expect_exit 44 bash "$fixture_dir/ci/test.sh" WallpaperExtensionTests/NewTests/testNew
[[ -e "$fixture_dir/generated" ]] || fail "line $LINENO"
expect_unregistered

# ci/test.sh refuses a name it can't find.
expect_exit 2 bash "$fixture_dir/ci/test.sh" NoSuchTests

# ci/xcodegen.sh refuses an XcodeGen on PATH that isn't the pinned version.
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 expect_exit 1 bash "$fixture_dir/ci/xcodegen.sh" generate
grep -Fq 'ci/bootstrap.sh' "$fixture_dir/command.log"

# ci/xcodegen.sh prefers the copy ci/bootstrap.sh installs in .tools.
mkdir -p "$fixture_dir/.tools/xcodegen/bin"
cat > "$fixture_dir/.tools/xcodegen/bin/xcodegen" <<'SH'
#!/bin/bash
touch "$LUMAWALL_GATE_MARKERS/pinned"
# A generator that writes a project different from the committed one.
case "${LUMAWALL_FAKE_XCODEGEN_DRIFT:-}" in
  edit) printf '/* drift */\n' >> "$LUMAWALL_GATE_MARKERS/LumaWall.xcodeproj/project.pbxproj" ;;
  new)
    mkdir -p "$LUMAWALL_GATE_MARKERS/LumaWall.xcodeproj/xcshareddata/xcschemes"
    touch "$LUMAWALL_GATE_MARKERS/LumaWall.xcodeproj/xcshareddata/xcschemes/New.xcscheme"
    ;;
esac
SH
chmod +x "$fixture_dir/.tools/xcodegen/bin/xcodegen"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 expect_exit 0 bash "$fixture_dir/ci/xcodegen.sh" generate
[[ -e "$fixture_dir/pinned" ]] || fail "line $LINENO"

# The local pin and CI's install step name the same XcodeGen release.
pin_values() {
    local pattern="$1"
    shift
    local file
    for file in "$@"; do
        grep -m1 -oiE "$pattern" "$file" | grep -oE '[0-9a-f.]+$' || printf 'missing in %s\n' "$file"
    done
}
workflow="$project_root/.github/workflows/wallpaper-checks.yml"
versions="$(pin_values 'xcodegen_version[=:] *[0-9.]+' \
    "$project_root/ci/xcodegen.sh" "$project_root/ci/bootstrap.sh" "$workflow" | sort -u)"
sums="$(pin_values 'xcodegen_sha256[=:] *[0-9a-f]{64}' "$project_root/ci/bootstrap.sh" "$workflow" | sort -u)"
if [[ "$versions" == *$'\n'* || "$versions" == missing* || "$sums" == *$'\n'* || "$sums" == missing* ]]; then
    printf 'XcodeGen pins disagree:\n%s\n%s\n' "$versions" "$sums" >&2
    exit 1
fi

# Release packaging requires a clean git checkout and targets the built HEAD commit.
cat > "$fixture_dir/.gitignore" <<'EOF'
*.log
.derived/
.tools/
bin/
dist/
origin.git/
results/
generated
packaged
pinned
staging-dir.txt
unregistered
EOF
git -C "$fixture_dir" init -q
git -C "$fixture_dir" add -A
git -C "$fixture_dir" -c user.name=Fixture -c user.email=fixture@example.com commit -q -m "initial fixture"

# A dirty working tree must refuse release before running checks or modifying dist/.
printf 'previous release\n' > "$fixture_dir/dist/LumaWall.dmg"
printf 'previous-checksum  LumaWall.dmg\n' > "$fixture_dir/dist/SHA256SUMS"
export DEVELOPER_ID_APPLICATION='Developer ID Application: Release Gate Fixture'
export DEVELOPMENT_TEAM='FIXTURE'
export NOTARY_KEYCHAIN_PROFILE='fixture-profile'
printf 'dirty\n' > "$fixture_dir/dirty.txt"
expect_exit 2 zsh "$fixture_dir/Packaging/release.sh"
rm -f "$fixture_dir/dirty.txt"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"
[[ ! -e "$fixture_dir/packaged" ]] || fail "line $LINENO"

# A failed validation must preserve an existing DMG and SHA256SUMS and never start packaging.
printf '#!/bin/bash\nexit 42\n' > "$fixture_dir/ci/check.sh"
git -C "$fixture_dir" add ci/check.sh
git -C "$fixture_dir" -c user.name=Fixture -c user.email=fixture@example.com commit -q -m "failing check fixture"
expect_exit 42 zsh "$fixture_dir/Packaging/release.sh"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"
[[ ! -e "$fixture_dir/packaged" ]] || fail "line $LINENO"

# Unknown release flags must be rejected before running checks or modifying dist/.
expect_exit 2 zsh "$fixture_dir/Packaging/release.sh" --bogus
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"

# Staging, pinned xcodegen, app notarization before DMG, and SHA256SUMS checks.
printf '#!/bin/bash\nexit 0\n' > "$fixture_dir/ci/check.sh"
git -C "$fixture_dir" add ci/check.sh
git -C "$fixture_dir" -c user.name=Fixture -c user.email=fixture@example.com commit -q -m "passing check fixture"
cat > "$fixture_dir/bin/xcodebuild" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/xcodebuild.log"
case " $* " in
  *" test "*) exit 44 ;;
  *" archive "*)
    archive_path=""
    derived_path=""
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "-archivePath" ]]; then
        archive_path="$arg"
      elif [[ "$prev" == "-derivedDataPath" ]]; then
        derived_path="$arg"
      fi
      prev="$arg"
    done
    if [[ -n "${LUMAWALL_FAKE_ARCHIVE_SIGNAL:-}" ]]; then
      mkdir -p "$derived_path/Build/Products/Release/LumaWall.app/Contents/Extensions/LumaWallWallpaper.appex"
      printf '%s\n' "$(dirname "$derived_path")" > "$LUMAWALL_GATE_MARKERS/staging-dir.txt"
      kill "-${LUMAWALL_FAKE_ARCHIVE_SIGNAL}" "$PPID"
      sleep 5
      exit 0
    fi
    mkdir -p "$archive_path/Products/Applications/LumaWall.app/Contents/MacOS" \
      "$archive_path/Products/Applications/LumaWall.app/Contents/XPCServices/LumaWallMediaService.xpc"
    cat > "$archive_path/Products/Applications/LumaWall.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.4.1</string></dict></plist>
PLIST
    exit 0
    ;;
  *) touch "$LUMAWALL_GATE_MARKERS/packaged"; exit 99 ;;
esac
SH
cat > "$fixture_dir/bin/codesign" <<'SH'
#!/bin/bash
case "$1" in
  -dvv)
    # The path says "flags=runtime" too, which must not count.
    if [[ -n "${LUMAWALL_FAKE_XPC_WITHOUT_RUNTIME:-}" && "$2" == *.xpc ]]; then
      printf 'Executable=/fixture/flags=runtime/LumaWallMediaService\n' >&2
      printf 'CodeDirectory v=20500 size=1 flags=0x0(none) hashes=1+1 location=embedded\n' >&2
    else
      printf 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded\n' >&2
    fi
    printf 'Timestamp=2026-11-19\n' >&2
    ;;
  -d)
    exit "${LUMAWALL_FAKE_CODESIGN_ENTITLEMENTS_EXIT:-0}"
    ;;
esac
SH
cat > "$fixture_dir/bin/ditto" <<'SH'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  printf 'zipped %s\n' "$4" >> "$LUMAWALL_GATE_MARKERS/release-steps.log"
  printf 'fake-zip\n' > "${@: -1}"
else
  mkdir -p "$2"
  cp -R "$1"/* "$2"/ 2>/dev/null || true
fi
SH
cat > "$fixture_dir/bin/hdiutil" <<'SH'
#!/bin/bash
printf 'hdiutil %s\n' "${@: -1}" >> "$LUMAWALL_GATE_MARKERS/release-steps.log"
printf 'new staged dmg\n' > "${@: -1}"
SH
cat > "$fixture_dir/bin/xcrun" <<'SH'
#!/bin/bash
printf 'xcrun %s %s %s\n' "$1" "$2" "$3" >> "$LUMAWALL_GATE_MARKERS/release-steps.log"
SH
cat > "$fixture_dir/bin/spctl" <<'SH'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/release-steps.log"
exit "${LUMAWALL_FAKE_SPCTL_EXIT:-0}"
SH
cat > "$fixture_dir/bin/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$LUMAWALL_GATE_MARKERS/release-steps.log"
SH
chmod +x "$fixture_dir/bin/"*

real_fixture_dir="$(cd "$fixture_dir" && pwd -P)"

# Failure during codesign entitlements inspection must fail closed and preserve dist/.
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_CODESIGN_ENTITLEMENTS_EXIT=1 expect_exit 3 zsh "$fixture_dir/Packaging/release.sh"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"

# A regenerated project that differs from the committed one must refuse
# release before archiving.
rm -f "$fixture_dir/xcodebuild.log"
LUMAWALL_FAKE_XCODEGEN_DRIFT=edit expect_exit 3 zsh "$fixture_dir/Packaging/release.sh"
grep -Fq 'LumaWall.xcodeproj' "$fixture_dir/command.log" || fail "line $LINENO"
! grep -Fq ' archive' "$fixture_dir/xcodebuild.log" 2>/dev/null || fail "line $LINENO"
git -C "$fixture_dir" checkout -q -- LumaWall.xcodeproj
# A new project file counts too, even where git hides untracked files.
git -C "$fixture_dir" config status.showUntrackedFiles no
LUMAWALL_FAKE_XCODEGEN_DRIFT=new expect_exit 3 zsh "$fixture_dir/Packaging/release.sh"
grep -Fq 'New.xcscheme' "$fixture_dir/command.log" || fail "line $LINENO"
! grep -Fq ' archive' "$fixture_dir/xcodebuild.log" 2>/dev/null || fail "line $LINENO"
rm -rf "$fixture_dir/LumaWall.xcodeproj/xcshareddata"
git -C "$fixture_dir" config --unset status.showUntrackedFiles
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"

# An XPC service signed without Hardened Runtime must refuse release.
LUMAWALL_FAKE_XPC_WITHOUT_RUNTIME=1 expect_exit 3 zsh "$fixture_dir/Packaging/release.sh"
grep -Fq 'Hardened Runtime is missing' "$fixture_dir/command.log" || fail "line $LINENO"
grep -Fq 'LumaWallMediaService.xpc' "$fixture_dir/command.log" || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"

# Failure during Gatekeeper verification must preserve existing dist/ outputs.
rm -f "$fixture_dir/pinned" "$fixture_dir/release-steps.log"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=1 expect_exit 1 zsh "$fixture_dir/Packaging/release.sh"
[[ -e "$fixture_dir/pinned" ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"

# SIGTERM during archive must still unregister builds, remove staging, and exit non-zero.
rm -f "$fixture_dir/unregistered" "$fixture_dir/staging-dir.txt"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_ARCHIVE_SIGNAL=TERM expect_exit 143 zsh "$fixture_dir/Packaging/release.sh"
grep -Fq "pluginkit -r " "$fixture_dir/unregistered" || fail "line $LINENO"
grep -Fq "lsregister -u " "$fixture_dir/unregistered" || fail "line $LINENO"
[[ "$(cat "$fixture_dir/staging-dir.txt")" == "$real_fixture_dir/dist/.staging."* ]] || fail "line $LINENO"
[[ ! -e "$(cat "$fixture_dir/staging-dir.txt")" ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ "$(cat "$fixture_dir/dist/SHA256SUMS")" == 'previous-checksum  LumaWall.dmg' ]] || fail "line $LINENO"

# Successful staging notarizes and staples the app before building the DMG, then swaps matched DMG + SHA256SUMS.
rm -f "$fixture_dir/release-steps.log"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 0 zsh "$fixture_dir/Packaging/release.sh"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'new staged dmg' ]] || fail "line $LINENO"
(cd "$fixture_dir/dist" && shasum -a 256 -c SHA256SUMS > /dev/null) || fail "line $LINENO"
grep -n 'xcrun notarytool submit .*LumaWall\.app\.zip' "$fixture_dir/release-steps.log" > /dev/null || fail "line $LINENO"
grep -n 'xcrun stapler staple .*LumaWall\.app' "$fixture_dir/release-steps.log" > /dev/null || fail "line $LINENO"
grep -n 'xcrun notarytool submit .*LumaWall\.dmg' "$fixture_dir/release-steps.log" > /dev/null || fail "line $LINENO"
app_zip_line="$(grep -n 'xcrun notarytool submit .*LumaWall\.app\.zip' "$fixture_dir/release-steps.log" | cut -d: -f1)"
dmg_create_line="$(grep -n 'hdiutil .*LumaWall\.dmg' "$fixture_dir/release-steps.log" | cut -d: -f1)"
[[ "$app_zip_line" -lt "$dmg_create_line" ]] || fail "line $LINENO"
! grep -Fq 'gh release create' "$fixture_dir/release-steps.log" || fail "line $LINENO"

# --publish creates a draft GitHub Release targeting the built HEAD commit even starting from an empty dist/.
release_commit="$(git -C "$fixture_dir" rev-parse HEAD)"
stale_commit="$(git -C "$fixture_dir" rev-parse HEAD~1)"
rm -rf "$fixture_dir/dist" "$fixture_dir/release-steps.log"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 0 zsh "$fixture_dir/Packaging/release.sh" --publish
grep -Fq "gh release create v0.4.1 --draft --target $release_commit --title LumaWall 0.4.1 --generate-notes $real_fixture_dir/dist/LumaWall.dmg $real_fixture_dir/dist/SHA256SUMS" "$fixture_dir/release-steps.log" || fail "line $LINENO"

# Existing local tag pointing to another commit must refuse --publish.
rm -f "$fixture_dir/release-steps.log"
git -C "$fixture_dir" tag v0.4.1 "$stale_commit"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 2 zsh "$fixture_dir/Packaging/release.sh" --publish
! grep -Fq 'gh release create' "$fixture_dir/release-steps.log" || fail "line $LINENO"

# Existing local annotated tag pointing to the built commit allows --publish.
rm -f "$fixture_dir/release-steps.log"
git -C "$fixture_dir" -c user.name=Fixture -c user.email=fixture@example.com tag -af -m "release v0.4.1" v0.4.1 "$release_commit"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 0 zsh "$fixture_dir/Packaging/release.sh" --publish
grep -Fq "gh release create v0.4.1 --draft --target $release_commit" "$fixture_dir/release-steps.log" || fail "line $LINENO"

# Existing remote tag on origin pointing to another commit must refuse --publish.
git -C "$fixture_dir" tag -d v0.4.1 > /dev/null
git init --bare -q "$fixture_dir/origin.git"
git -C "$fixture_dir" remote add origin "$fixture_dir/origin.git"
git -C "$fixture_dir" push -q origin "$release_commit:refs/heads/main"
git -C "$fixture_dir" tag v0.4.1 "$stale_commit"
git -C "$fixture_dir" push -q origin refs/tags/v0.4.1
git -C "$fixture_dir" tag -d v0.4.1 > /dev/null
rm -f "$fixture_dir/release-steps.log"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 2 zsh "$fixture_dir/Packaging/release.sh" --publish
! grep -Fq 'gh release create' "$fixture_dir/release-steps.log" || fail "line $LINENO"

# Matching annotated remote tag on origin allows --publish.
git -C "$fixture_dir" -c user.name=Fixture -c user.email=fixture@example.com tag -a -m "release v0.4.1" v0.4.1 "$release_commit"
git -C "$fixture_dir" push -q --force origin refs/tags/v0.4.1
git -C "$fixture_dir" tag -d v0.4.1 > /dev/null
rm -f "$fixture_dir/release-steps.log"
LUMAWALL_FAKE_XCODEGEN_VERSION=2.47.0 LUMAWALL_FAKE_SPCTL_EXIT=0 expect_exit 0 zsh "$fixture_dir/Packaging/release.sh" --publish
grep -Fq "gh release create v0.4.1 --draft --target $release_commit" "$fixture_dir/release-steps.log" || fail "line $LINENO"

printf 'Core, playback, release, cleanup, and ci/test.sh gates passed.\n'
