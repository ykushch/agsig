#!/bin/bash
# Package NotchApp into a proper .app bundle with a stable identity, then ad-hoc
# sign it so macOS TCC (Accessibility) can track it. Global hotkeys (⌥Y/⌥N/⌥+arrows)
# require Accessibility, which will NOT work when running the bare `swift run`
# executable from .build/ — macOS needs a signed .app with a stable bundle id.
#
# Usage: ./bundle.sh [release|debug]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="NotchApp"
BUNDLE_ID="dev.notchagent.NotchApp"
OUT="build/${APP}.app"

echo "Building ($CONFIG)"
swift build -c "$CONFIG" --product "$APP"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP}"

echo "Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP}"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>${APP}</string>
    <key>CFBundleDisplayName</key>         <string>Notch Agent</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleExecutable</key>          <string>${APP}</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <!-- Accessory app: no Dock icon, non-activating (matches setActivationPolicy(.accessory)). -->
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# Ad-hoc code signing gives the bundle a stable identity for TCC across runs.
# (A real Developer ID cert would be needed for distribution; ad-hoc is fine for
# personal use — the Accessibility grant sticks to this signed bundle.)
echo "Ad-hoc signing"
codesign --force --deep --sign - "$OUT"

echo "Done: $OUT"
echo
echo "Launch it (NOT 'swift run') so Accessibility can track it:"
echo "  open $OUT"
echo
echo "Then grant: System Settings → Privacy & Security → Accessibility → enable 'Notch Agent'."
echo "If it was previously denied, remove any stale entry with the − button first."
