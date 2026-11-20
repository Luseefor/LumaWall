#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Packaging/release.sh [--publish]

Builds, signs, notarizes, staples, and verifies LumaWall.app and LumaWall.dmg,
then writes dist/LumaWall.dmg and dist/SHA256SUMS.

Options:
  --publish   Create a draft GitHub Release with dist/LumaWall.dmg and dist/SHA256SUMS via gh
  -h, --help  Show this help
EOF
}

publish=0
while (( $# > 0 )); do
    case "$1" in
        --publish)
            publish=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

project_root="${0:A:h:h}"
output_dir="${project_root}/dist"
dmg_path="${output_dir}/LumaWall.dmg"
checksums_path="${output_dir}/SHA256SUMS"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the full Developer ID Application identity}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer Team ID}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to a notarytool Keychain profile}"

if [[ "${DEVELOPER_ID_APPLICATION}" != Developer\ ID\ Application:* ]]; then
    print -u2 "Refusing release: DEVELOPER_ID_APPLICATION must begin with 'Developer ID Application:'."
    exit 2
fi

if ! security find-identity -v -p codesigning | grep -Fq "${DEVELOPER_ID_APPLICATION}"; then
    print -u2 "Refusing release: the requested Developer ID identity is not installed."
    exit 2
fi

if (( publish )) && ! command -v gh >/dev/null 2>&1; then
    print -u2 "Refusing --publish: gh CLI is required."
    exit 2
fi

cd "${project_root}"
if ! git_status="$(git -C "${project_root}" status --porcelain 2>&1)"; then
    print -u2 "Refusing release: unable to inspect git working tree in ${project_root}."
    print -u2 "${git_status}"
    exit 2
fi
if [[ -n "${git_status}" ]]; then
    print -u2 "Refusing release: git working tree is dirty; commit or stash changes first."
    print -u2 "${git_status}"
    exit 2
fi
if ! release_commit="$(git -C "${project_root}" rev-parse --verify HEAD 2>&1)"; then
    print -u2 "Refusing release: unable to resolve HEAD commit."
    print -u2 "${release_commit}"
    exit 2
fi

"${project_root}/ci/check.sh"

mkdir -p "${output_dir}"
staging_dir="$(mktemp -d "${output_dir}/.staging.XXXXXX")"
archive_path="${staging_dir}/LumaWall.xcarchive"
derived_data_path="${staging_dir}/derived"
app_zip="${staging_dir}/LumaWall.app.zip"
dmg_root="${staging_dir}/dmg-root"
staged_dmg="${staging_dir}/LumaWall.dmg"
staged_checksums="${staging_dir}/SHA256SUMS"
app_path="${archive_path}/Products/Applications/LumaWall.app"

cleanup() {
    local lsregister="${LUMAWALL_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
    if [[ -n "${derived_data_path:-}" && -d "${derived_data_path}" ]]; then
        "${project_root}/ci/unregister-builds.sh" "${derived_data_path}" || true
    fi
    if [[ -n "${app_path:-}" && -d "${app_path}" ]]; then
        pluginkit -r "${app_path}/Contents/Extensions/LumaWallWallpaper.appex" 2>/dev/null || true
        "${lsregister}" -u "${app_path}" 2>/dev/null || true
    fi
    if [[ -n "${staging_dir:-}" ]]; then
        rm -rf "${staging_dir}"
    fi
}

on_int() {
    trap - EXIT INT TERM
    cleanup
    exit 130
}

on_term() {
    trap - EXIT INT TERM
    cleanup
    exit 143
}

trap cleanup EXIT
trap on_int INT
trap on_term TERM

"${project_root}/ci/xcodegen.sh" generate
# The archive must build the committed project, the one the tag names.
if ! project_status="$(git -C "${project_root}" status --porcelain -- LumaWall.xcodeproj 2>&1)" \
    || [[ -n "${project_status}" ]] \
    || ! git -C "${project_root}" diff --quiet --exit-code -- LumaWall.xcodeproj; then
    print -u2 "Refusing release: regenerating LumaWall.xcodeproj changed it; commit the regenerated project first."
    print -u2 "${project_status}"
    exit 3
fi
xcodebuild \
    -project LumaWall.xcodeproj \
    -scheme LumaWall \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${derived_data_path}" \
    -archivePath "${archive_path}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

[[ -d "${app_path}" ]] || { print -u2 "Archive did not contain LumaWall.app"; exit 3; }

codesign --verify --deep --strict --verbose=2 "${app_path}"
# Every nested bundle: helper apps, extensions, XPC services, frameworks.
if ! nested_items="$(find "${app_path}/Contents" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.framework' \) -print0)"; then
    print -u2 "Refusing release: failed to enumerate nested code inside ${app_path}."
    exit 3
fi
# Split on NUL, so a bundle name holding a newline stays one path.
signed_items=("${(@0)nested_items}")
signed_items=(${signed_items:#})
signed_items+=("${app_path}")

for signed_item in "${signed_items[@]}"; do
    if ! signature_details="$(codesign -dvv "${signed_item}" 2>&1)"; then
        print -u2 "Refusing release: failed to inspect signature for ${signed_item}."
        print -u2 "${signature_details}"
        exit 3
    fi
    # The CodeDirectory line's flags, not a path that happens to say runtime.
    if ! grep -Eq '^CodeDirectory .*[[:space:]]flags=0x[0-9a-fA-F]+\([^)]*runtime' <<<"${signature_details}"; then
        print -u2 "Refusing release: Hardened Runtime is missing from ${signed_item}."
        exit 3
    fi
    if ! grep -q '^Timestamp=' <<<"${signature_details}"; then
        print -u2 "Refusing release: secure timestamp is missing from ${signed_item}."
        exit 3
    fi
    if ! entitlements="$(codesign -d --entitlements - "${signed_item}" 2>&1)"; then
        print -u2 "Refusing release: failed to inspect entitlements for ${signed_item}."
        print -u2 "${entitlements}"
        exit 3
    fi
    if grep -A1 -q 'com.apple.security.get-task-allow' <<<"${entitlements}"; then
        print -u2 "Refusing release: get-task-allow is present in ${signed_item}."
        exit 3
    fi
done

ditto -c -k --keepParent "${app_path}" "${app_zip}"
xcrun notarytool submit "${app_zip}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${app_path}"
xcrun stapler validate "${app_path}"
spctl --assess --type execute --verbose=4 "${app_path}"

mkdir -p "${dmg_root}"
ditto "${app_path}" "${dmg_root}/LumaWall.app"
ln -s /Applications "${dmg_root}/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname LumaWall -srcfolder "${dmg_root}" "${staged_dmg}"
codesign --force --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${staged_dmg}"
xcrun notarytool submit "${staged_dmg}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${staged_dmg}"
xcrun stapler validate "${staged_dmg}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${staged_dmg}"

(cd "${staging_dir}" && shasum -a 256 "LumaWall.dmg" > "${staged_checksums}")

backup_dir="${staging_dir}/backup"
mkdir -p "${backup_dir}"
trap '' INT TERM
if [[ -e "${dmg_path}" ]]; then
    mv -f "${dmg_path}" "${backup_dir}/LumaWall.dmg"
fi
if [[ -e "${checksums_path}" ]]; then
    mv -f "${checksums_path}" "${backup_dir}/SHA256SUMS"
fi
if ! { mv -f "${staged_dmg}" "${dmg_path}" && mv -f "${staged_checksums}" "${checksums_path}"; }; then
    if [[ -e "${backup_dir}/LumaWall.dmg" ]]; then
        mv -f "${backup_dir}/LumaWall.dmg" "${dmg_path}" || true
    fi
    if [[ -e "${backup_dir}/SHA256SUMS" ]]; then
        mv -f "${backup_dir}/SHA256SUMS" "${checksums_path}" || true
    fi
    trap on_int INT
    trap on_term TERM
    print -u2 "Refusing release: failed to promote DMG and SHA256SUMS into ${output_dir}."
    exit 3
fi
trap on_int INT
trap on_term TERM

print "Production DMG ready: ${dmg_path}"
print "Checksums ready: ${checksums_path}"

if (( publish )); then
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_path}/Contents/Info.plist")"
    release_tag="v${app_version}"

    if git -C "${project_root}" show-ref --verify --quiet "refs/tags/${release_tag}"; then
        if ! local_tag_commit="$(git -C "${project_root}" rev-parse --verify "refs/tags/${release_tag}^{commit}" 2>&1)"; then
            print -u2 "Refusing --publish: local tag ${release_tag} does not resolve to a commit."
            print -u2 "${local_tag_commit}"
            exit 2
        fi
        if [[ "${local_tag_commit}" != "${release_commit}" ]]; then
            print -u2 "Refusing --publish: local tag ${release_tag} resolves to ${local_tag_commit}, expected ${release_commit}."
            exit 2
        fi
    fi

    if git -C "${project_root}" remote get-url origin >/dev/null 2>&1; then
        if ! remote_tag_refs="$(git -C "${project_root}" ls-remote --tags origin "refs/tags/${release_tag}" "refs/tags/${release_tag}^{}" 2>&1)"; then
            print -u2 "Refusing --publish: failed to inspect remote tags on origin."
            print -u2 "${remote_tag_refs}"
            exit 2
        fi
        if [[ -n "${remote_tag_refs}" ]]; then
            remote_tag_commit=""
            while IFS=$'\t' read -r ref_sha ref_name; do
                if [[ "${ref_name}" == "refs/tags/${release_tag}^{}" ]]; then
                    remote_tag_commit="${ref_sha}"
                    break
                elif [[ "${ref_name}" == "refs/tags/${release_tag}" && -z "${remote_tag_commit}" ]]; then
                    remote_tag_commit="${ref_sha}"
                fi
            done <<< "${remote_tag_refs}"
            if [[ "${remote_tag_commit}" != "${release_commit}" ]]; then
                print -u2 "Refusing --publish: remote tag ${release_tag} resolves to ${remote_tag_commit}, expected ${release_commit}."
                exit 2
            fi
        fi
    fi

    gh release create "${release_tag}" \
        --draft \
        --target "${release_commit}" \
        --title "LumaWall ${app_version}" \
        --generate-notes \
        "${dmg_path}" \
        "${checksums_path}"
    print "Draft GitHub Release created: ${release_tag} (${release_commit})"
fi
