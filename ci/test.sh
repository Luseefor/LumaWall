#!/bin/bash
# Runs a narrow set of tests instead of the full ./ci/check.sh.
#
#   ci/test.sh RendererLifecycleTests
#   ci/test.sh RendererLifecycleTests/testStopReleasesSurface
#   ci/test.sh WallpaperExtensionTests/RendererLifecycleTests/testX
#   ci/test.sh core                  # every swift test in LumaWallCoreTests
#   ci/test.sh PowerPolicyTests      # a core suite runs with swift test --filter
#
# Several names can be given at once. Names are looked up under Tests/; a
# name in Tests/LumaWallCoreTests runs with swift test, anything else with
# xcodebuild -only-testing in the same Testing configuration as check.sh.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
    sed -n '2,12s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
}
[[ $# -gt 0 ]] || usage

core_filters=()
xcode_tests=()
xcode_files=()

for name in "$@"; do
    case "$name" in
        -h|--help) usage ;;
        core|LumaWallCoreTests) core_filters+=("LumaWallCoreTests"); continue ;;
    esac
    IFS=/ read -r first rest <<< "$name"
    if [[ -d "Tests/$first" ]]; then
        target="$first"
        IFS=/ read -r type_name method <<< "$rest"
    else
        type_name="$first"
        method="$rest"
        matches=()
        while IFS= read -r file; do
            matches+=("$file")
        done < <(grep -rlE "(class|struct)[[:space:]]+${type_name}([^[:alnum:]_]|$)" Tests 2>/dev/null || true)
        if [[ ${#matches[@]} -eq 0 ]]; then
            printf 'No test class or suite named %s under Tests/.\n' "$type_name" >&2
            exit 2
        fi
        targets="$(printf '%s\n' "${matches[@]}" | cut -d/ -f2 | sort -u)"
        if [[ "$(printf '%s\n' "$targets" | wc -l)" -gt 1 ]]; then
            printf '%s is in more than one target; prefix one of:\n%s\n' "$type_name" "$targets" >&2
            exit 2
        fi
        target="$targets"
        xcode_files+=("${matches[@]}")
    fi
    if [[ "$target" == LumaWallCoreTests ]]; then
        core_filters+=("LumaWallCoreTests${type_name:+\\.$type_name}${method:+/$method}")
    else
        xcode_tests+=("-only-testing:$target${type_name:+/$type_name}${method:+/$method}")
    fi
done

if [[ ${#core_filters[@]} -gt 0 ]]; then
    filter="$(IFS='|'; printf '%s' "${core_filters[*]}")"
    swift test --filter "$filter"
fi

[[ ${#xcode_tests[@]} -gt 0 ]] || exit 0

# The build registers LumaWall.app with macOS, which can take over the live
# wallpaper. Unregister it however this script exits.
trap '"$project_root/ci/unregister-builds.sh" "$project_root/.derived"' EXIT

# Regenerate only when the project is stale: project.yml changed, or a test
# file was added since the last generate.
pbxproj=LumaWall.xcodeproj/project.pbxproj
stale=0
[[ project.yml -nt "$pbxproj" ]] && stale=1
for file in ${xcode_files[@]+"${xcode_files[@]}"}; do
    grep -Fq "$(basename "$file")" "$pbxproj" || stale=1
done
[[ "$stale" == 1 ]] && xcodegen generate

output_root="${LUMAWALL_CHECK_OUTPUT_DIR:-$project_root/.derived/checks}"
mkdir -p "$output_root"
run_dir="$(mktemp -d "$output_root/test.XXXXXX")"
printf 'Results: %s\n' "$run_dir"

# Same configuration and flags as the Testing run in check.sh.
xcodebuild \
    -project LumaWall.xcodeproj \
    -scheme LumaWall \
    -configuration Testing \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath .derived \
    -resultBundlePath "$run_dir/Tests.xcresult" \
    -parallel-testing-enabled NO \
    CODE_SIGN_IDENTITY=- \
    ENABLE_HARDENED_RUNTIME=NO \
    "${xcode_tests[@]}" \
    test 2>&1 | tee "$run_dir/tests.log"
