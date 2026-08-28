#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_dir="${project_root}/dist"
archive_path="${output_dir}/LumaWall.xcarchive"
dmg_root="${output_dir}/dmg-root"
dmg_path="${output_dir}/LumaWall.dmg"

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

mkdir -p "${output_dir}"
rm -rf "${archive_path}" "${dmg_root}"
rm -f "${dmg_path}"

cd "${project_root}"
xcodegen generate
xcodebuild \
    -project LumaWall.xcodeproj \
    -scheme LumaWall \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${archive_path}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

app_path="${archive_path}/Products/Applications/LumaWall.app"
[[ -d "${app_path}" ]] || { print -u2 "Archive did not contain LumaWall.app"; exit 3; }

codesign --verify --deep --strict --verbose=2 "${app_path}"
while IFS= read -r signed_item; do
    signature_details="$(codesign -dvv "${signed_item}" 2>&1)"
    if ! grep -q 'flags=.*runtime' <<<"${signature_details}"; then
        print -u2 "Refusing release: Hardened Runtime is missing from ${signed_item}."
        exit 3
    fi
    if ! grep -q '^Timestamp=' <<<"${signature_details}"; then
        print -u2 "Refusing release: secure timestamp is missing from ${signed_item}."
        exit 3
    fi
    if codesign -d --entitlements - "${signed_item}" 2>/dev/null | grep -A1 -q 'com.apple.security.get-task-allow'; then
        print -u2 "Refusing release: get-task-allow is present in ${signed_item}."
        exit 3
    fi
done < <(find "${app_path}/Contents" -type d \( -name '*.appex' -o -name '*.framework' \); print -r -- "${app_path}")

mkdir -p "${dmg_root}"
ditto "${app_path}" "${dmg_root}/LumaWall.app"
ln -s /Applications "${dmg_root}/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname LumaWall -srcfolder "${dmg_root}" "${dmg_path}"
codesign --force --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${dmg_path}"
xcrun notarytool submit "${dmg_path}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${dmg_path}"
xcrun stapler validate "${dmg_path}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${dmg_path}"

print "Production DMG ready: ${dmg_path}"
