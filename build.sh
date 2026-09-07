#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/DNSToggle.app"
BIN="$APP/Contents/MacOS/DNSToggle"
HELPER_SRC="$ROOT/MenuBar/dns-toggle-helper"
UNBRICK_SRC="$ROOT/MenuBar/dnstoggle-unbrick.sh"
INSTALL_SRC="$ROOT/MenuBar/install-helper.sh"

echo "Building DNSToggle..."
cd "$ROOT"
swift build -c release

# Quit old competing apps so two globe icons don't fight.
pkill -9 -f "/Applications/DNS.app/Contents/MacOS/DNS" 2>/dev/null || true
pkill -9 -x DNS 2>/dev/null || true
pkill -9 -f "/Applications/DNSToggle.app/Contents/MacOS/DNSToggle" 2>/dev/null || true
pkill -9 -x DNSToggle 2>/dev/null || true

# Keep Spotlight clean — only one app.
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf /Applications/DNS.app "$ROOT/DNSToggle.app" "$ROOT/DNSTogglePy.app"
"$LS" -u /Applications/DNS.app 2>/dev/null || true

rm -rf "$APP" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/DNSToggle" "$BIN"
cp "$HELPER_SRC" "$APP/Contents/Resources/dns-toggle-helper"
cp "$UNBRICK_SRC" "$APP/Contents/Resources/dnstoggle-unbrick.sh"
cp "$INSTALL_SRC" "$APP/Contents/Resources/install-helper.sh"
chmod +x "$BIN" \
         "$APP/Contents/Resources/dns-toggle-helper" \
         "$APP/Contents/Resources/dnstoggle-unbrick.sh" \
         "$APP/Contents/Resources/install-helper.sh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DNSToggle</string>
    <key>CFBundleIdentifier</key>
    <string>com.rahulmasand.dnstoggle</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DNSToggle</string>
    <key>CFBundleDisplayName</key>
    <string>DNSToggle</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.5</string>
    <key>CFBundleVersion</key>
    <string>7</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP" 2>/dev/null || true

# Stable signing so Keychain trusts the same app across rebuilds.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$SIGN_ID" ]; then
  codesign -s "$SIGN_ID" --force --deep --options runtime "$APP"
else
  codesign -s - --force --deep "$APP"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"

echo "Installed and launched /Applications/DNSToggle.app (v2.5) — look for the globe in the menu bar."
echo "If Connect is blocked: click Enable password-free switching… once."
