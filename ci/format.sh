#!/bin/bash
# Formats the Swift sources in place with the toolchain's swift format and
# the repo's .swift-format. ci/check.sh lints the same paths.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

swift format format --in-place --parallel --recursive Sources WallpaperExtension Tests
