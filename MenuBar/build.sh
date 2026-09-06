#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/DNS.app"

pkill -9 -f "/Applications/DNS.app/Contents/MacOS/DNS" 2>/dev/null || true
pkill -9 -x DNS 2>/dev/null || true
rm -rf "$APP" ~/Developer/DNSToggle/DNSToggle.app ~/Developer/DNSToggle/DNSTogglePy.app 2>/dev/null || true

swiftc "$ROOT/main.swift" -O -o "$ROOT/dns" -framework AppKit -framework Foundation -framework Security

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/dns" "$APP/Contents/MacOS/DNS"
cp "$ROOT/dns-toggle-helper" "$APP/Contents/Resources/dns-toggle-helper"
cp "$ROOT/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
chmod +x "$APP/Contents/MacOS/DNS" \
         "$APP/Contents/Resources/dns-toggle-helper" \
         "$APP/Contents/Resources/install-helper.sh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DNS</string>
    <key>CFBundleIdentifier</key><string>com.rahulmasand.dns</string>
    <key>CFBundleName</key><string>DNS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
# Stable signing so Keychain trusts the same app across rebuilds (adhoc `-` changes every build).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$SIGN_ID" ]; then
  codesign -s "$SIGN_ID" --force --deep --options runtime "$APP"
else
  codesign -s - --force --deep "$APP"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"

echo "Installed and launched /Applications/DNS.app — look for 'DNS' in the menu bar."
