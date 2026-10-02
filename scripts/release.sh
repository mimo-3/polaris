#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${NOTARY_PROFILE:-polaris-notary}"
./scripts/bundle.sh
app="build/Polaris.app"
dmg="build/Polaris.dmg"
signature="$(codesign -dvv "$app" 2>&1)"
if [[ "$signature" != *$'\nAuthority=Developer ID Application:'* ]]; then
    echo "Developer ID Application で署名されていません" >&2
    exit 1
fi
identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2; exit}')"
staging="$(mktemp -d)"
mount=""
cleanup() {
    if [[ -n "$mount" ]]; then
        hdiutil detach "$mount" -force >/dev/null 2>&1 || true
        rm -rf "$mount"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$app" "$staging/Polaris.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname Polaris -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
result="$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)" || true
echo "$result"
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile"
    exit 1
fi
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
mount="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null
spctl -a -vv -t exec "$mount/Polaris.app"
echo "Created $dmg"
