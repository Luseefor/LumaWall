#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

"$project_root/ci/test-failure-gates.sh"

output_root="${LUMAWALL_CHECK_OUTPUT_DIR:-$project_root/.derived/checks}"
mkdir -p "$output_root"
run_dir="$(mktemp -d "$output_root/run.XXXXXX")"
printf 'Validation results: %s\n' "$run_dir"

swift test 2>&1 | tee "$run_dir/core-tests.log"
xcodegen generate

# Testing uses a separate bundle id and a minimal app host. It never starts
# AppModel or restores the wallpapers in the person's library.
xcodebuild \
    -project LumaWall.xcodeproj \
    -scheme LumaWall \
    -configuration Testing \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath .derived \
    -resultBundlePath "$run_dir/WallpaperTests.xcresult" \
    -parallel-testing-enabled NO \
    CODE_SIGN_IDENTITY=- \
    ENABLE_HARDENED_RUNTIME=NO \
    test 2>&1 | tee "$run_dir/playback-tests.log"

# Compile the production entry point as well as the isolated test host.
xcodebuild \
    -project LumaWall.xcodeproj \
    -scheme LumaWall \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath .derived \
    CODE_SIGN_IDENTITY=- \
    ENABLE_HARDENED_RUNTIME=NO \
    build 2>&1 | tee "$run_dir/release-build.log"
codesign --verify --deep --strict .derived/Build/Products/Release/LumaWall.app

printf 'Core tests, playback tests, and release build passed. Results: %s\n' "$run_dir"
