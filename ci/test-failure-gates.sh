#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/ci" "$fixture_dir/Packaging" "$fixture_dir/bin" "$fixture_dir/dist"
cp "$project_root/ci/check.sh" "$fixture_dir/ci/check.sh"
cp "$project_root/ci/unregister-builds.sh" "$fixture_dir/ci/unregister-builds.sh"
cp "$project_root/ci/test.sh" "$fixture_dir/ci/test.sh"
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
[[ ! -e "$fixture_dir/generated" ]]
expect_unregistered

# A playback failure must stop before compiling a release.
expect_exit 44 bash "$fixture_dir/ci/check.sh"
[[ -e "$fixture_dir/generated" && ! -e "$fixture_dir/packaged" ]]
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
touch -t 202001010000 "$fixture_dir/project.yml"
rm -f "$fixture_dir/swift.log" "$fixture_dir/xcodebuild.log" "$fixture_dir/generated"
expect_exit 0 bash "$fixture_dir/ci/test.sh" PowerPolicyTests/testBattery
grep -Fqx 'test --filter LumaWallCoreTests\.PowerPolicyTests/testBattery' "$fixture_dir/swift.log"
[[ ! -e "$fixture_dir/xcodebuild.log" ]]

# ci/test.sh runs an extension test class with -only-testing, keeps the
# xcodebuild failure, skips xcodegen while the project is current, and
# unregisters the built app.
expect_exit 44 bash "$fixture_dir/ci/test.sh" RendererLifecycleTests/testStop
grep -Fq ' -configuration Testing ' "$fixture_dir/xcodebuild.log"
grep -Fq ' -only-testing:WallpaperExtensionTests/RendererLifecycleTests/testStop ' "$fixture_dir/xcodebuild.log"
[[ ! -e "$fixture_dir/generated" ]]
expect_unregistered

# ci/test.sh regenerates the project once project.yml is newer.
touch "$fixture_dir/project.yml"
expect_exit 44 bash "$fixture_dir/ci/test.sh" WallpaperExtensionTests/RendererLifecycleTests
[[ -e "$fixture_dir/generated" ]]
expect_unregistered

# ci/test.sh refuses a name it can't find.
expect_exit 2 bash "$fixture_dir/ci/test.sh" NoSuchTests

# A failed validation must preserve an existing DMG and never start packaging.
printf '#!/bin/bash\nexit 42\n' > "$fixture_dir/ci/check.sh"
printf 'previous release\n' > "$fixture_dir/dist/LumaWall.dmg"
export DEVELOPER_ID_APPLICATION='Developer ID Application: Release Gate Fixture'
export DEVELOPMENT_TEAM='FIXTURE'
export NOTARY_KEYCHAIN_PROFILE='fixture-profile'
expect_exit 42 zsh "$fixture_dir/Packaging/release.sh"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]]
[[ ! -e "$fixture_dir/packaged" ]]

printf 'Core, playback, release, cleanup, and ci/test.sh gates passed.\n'
