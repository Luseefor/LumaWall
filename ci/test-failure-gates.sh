#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/ci" "$fixture_dir/Packaging" "$fixture_dir/bin" "$fixture_dir/dist"
cp "$project_root/ci/check.sh" "$fixture_dir/ci/check.sh"
cp "$project_root/ci/unregister-builds.sh" "$fixture_dir/ci/unregister-builds.sh"
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

# A failed validation must preserve an existing DMG and never start packaging.
printf '#!/bin/bash\nexit 42\n' > "$fixture_dir/ci/check.sh"
printf 'previous release\n' > "$fixture_dir/dist/LumaWall.dmg"
export DEVELOPER_ID_APPLICATION='Developer ID Application: Release Gate Fixture'
export DEVELOPMENT_TEAM='FIXTURE'
export NOTARY_KEYCHAIN_PROFILE='fixture-profile'
expect_exit 42 zsh "$fixture_dir/Packaging/release.sh"
[[ "$(cat "$fixture_dir/dist/LumaWall.dmg")" == 'previous release' ]] || fail "line $LINENO"
[[ ! -e "$fixture_dir/packaged" ]] || fail "line $LINENO"

printf 'Core, playback, release, and cleanup failure gates passed.\n'
