#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${NOTARY_PROFILE:-polaris-notary}"
./scripts/bundle.sh
app="build/Polaris.app"
dmg="build/Polaris.dmg"
signature="$(codesign -dvv "$app" 2>&1)"
identity="$(awk -F= '/^Authority=Developer ID Application:/ {print $2; exit}' <<<"$signature")"
if [[ -z "$identity" ]]; then
    echo "Developer ID Application で署名されていません" >&2
    exit 1
fi
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname Polaris -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
result="$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)"
echo "$result"
if ! grep -q '"status":"Accepted"' <<<"$result"; then
    id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"$result")"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile"
    exit 1
fi
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
mount="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null
spctl -a -vv -t exec "$mount/Polaris.app" || { hdiutil detach "$mount" >/dev/null; exit 1; }
hdiutil detach "$mount" >/dev/null
echo "Created $dmg"
