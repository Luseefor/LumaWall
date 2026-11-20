#!/bin/bash
# Building LumaWall.app registers its wallpaper extension with macOS, and the
# system can then play the built copy in place of /Applications/LumaWall.app.
# This unregisters every LumaWall.app built under a derived data path
# (default: .derived). Run it after any raw xcodebuild.
set -uo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${1:-$project_root/.derived}"
lsregister="${LUMAWALL_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

shopt -s nullglob
for app in "$derived_data"/Build/Products/*/LumaWall.app; do
    pluginkit -r "$app/Contents/Extensions/LumaWallWallpaper.appex" 2>/dev/null || true
    "$lsregister" -u "$app" 2>/dev/null || true
    printf 'Unregistered %s\n' "$app"
done
