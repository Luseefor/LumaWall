#!/bin/bash
# Runs the XcodeGen version the committed LumaWall.xcodeproj is generated
# with. Other versions write a different project and fail CI's
# committed-project check.
set -euo pipefail

# Keep in step with ci/bootstrap.sh and .github/workflows/wallpaper-checks.yml.
xcodegen_version=2.46.0

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pinned="$project_root/.tools/xcodegen/bin/xcodegen"

if [[ -x "$pinned" ]]; then
    exec "$pinned" "$@"
fi
if command -v xcodegen > /dev/null && xcodegen --version | grep -Fqx "Version: $xcodegen_version"; then
    exec xcodegen "$@"
fi
found="$(xcodegen --version 2>/dev/null || printf 'no xcodegen on PATH')"
printf 'XcodeGen %s is required (found: %s). Run ci/bootstrap.sh.\n' "$xcodegen_version" "$found" >&2
exit 1
