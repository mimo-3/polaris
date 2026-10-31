#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${VERSION:-$(sed -n 's/.*static let defaultVersion = "\([^"]*\)".*/\1/p' Sources/PolarisCore/PolarisVersion.swift)}"
[[ -n "$version" ]] || { echo "VERSION が空です" >&2; exit 1; }
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/Polaris.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PolarisApp" "$app/Contents/MacOS/Polaris"
cp "$bin_dir/polaris-mcp" "$app/Contents/MacOS/polaris-mcp"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Polaris</string>
<key>CFBundleDisplayName</key><string>Polaris</string>
<key>CFBundleIdentifier</key><string>dev.mimo.polaris</string>
<key>CFBundleExecutable</key><string>Polaris</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$app/Contents/Info.plist" "${BUNDLE_IDENTIFIER:-dev.mimo.polaris}" "$version" "$build_number" <<'PYPLIST'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info.update(CFBundleIdentifier=sys.argv[2], CFBundleShortVersionString=sys.argv[3], CFBundleVersion=sys.argv[4])
path.write_bytes(plistlib.dumps(info))
PYPLIST
# An optional native icon can be supplied by the UI implementation.
if [[ -f Resources/Polaris.icns ]]; then
    cp Resources/Polaris.icns "$app/Contents/Resources/Polaris.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Polaris' "$app/Contents/Info.plist"
fi
identity="${SIGNING_IDENTITY:--}"
# Notarization requires a secure timestamp, which ad-hoc signatures cannot carry.
timestamp=()
[[ "$identity" != "-" ]] && timestamp=(--timestamp)
codesign --force --options runtime ${timestamp[@]+"${timestamp[@]}"} --sign "$identity" "$app/Contents/MacOS/polaris-mcp"
codesign --force --options runtime ${timestamp[@]+"${timestamp[@]}"} --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Created $app"
