#!/bin/bash
# Installs the XcodeGen release CI uses into .tools/xcodegen. The committed
# LumaWall.xcodeproj is generated with this version; other versions write a
# different project and fail CI's committed-project check.
set -euo pipefail

# Keep in step with ci/xcodegen.sh and .github/workflows/wallpaper-checks.yml.
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools_dir="$project_root/.tools"
xcodegen="$tools_dir/xcodegen/bin/xcodegen"

if [[ -x "$xcodegen" ]] && "$xcodegen" --version | grep -Fq "$xcodegen_version"; then
    printf 'XcodeGen %s is already in %s\n' "$xcodegen_version" "$tools_dir/xcodegen"
    exit 0
fi

download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT
curl -fsSL -o "$download_dir/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip"
echo "$xcodegen_sha256  $download_dir/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$download_dir/xcodegen.zip" -d "$download_dir/unpacked"

mkdir -p "$tools_dir"
rm -rf "$tools_dir/xcodegen"
mv "$download_dir/unpacked/xcodegen" "$tools_dir/xcodegen"
"$xcodegen" --version
