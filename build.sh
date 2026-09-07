#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/DNSToggle.app"
BIN="$APP/Contents/MacOS/DNSToggle"
HELPER_SRC="$ROOT/MenuBar/dns-toggle-helper"
UNBRICK_SRC="$ROOT/MenuBar/dnstoggle-unbrick.sh"
INSTALL_SRC="$ROOT/MenuBar/install-helper.sh"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "Building DNSToggle..."
cd "$ROOT"
swift build -c release

echo "Stopping every old DNS / DNSToggle process…"
pkill -9 -f "/Applications/DNS.app/Contents/MacOS/DNS" 2>/dev/null || true
pkill -9 -x DNS 2>/dev/null || true
pkill -9 -f "/Applications/DNSToggle.app/Contents/MacOS/DNSToggle" 2>/dev/null || true
pkill -9 -x DNSToggle 2>/dev/null || true
# Catch stray builds launched from Desktop / Downloads / project folder.
pkill -9 -f "DNSToggle.app/Contents/MacOS/DNSToggle" 2>/dev/null || true
pkill -9 -f "DNSTogglePy" 2>/dev/null || true

echo "Removing duplicate apps so only /Applications/DNSToggle.app remains…"
# Legacy names + any copy outside Applications.
rm -rf /Applications/DNS.app \
       /Applications/DNSTogglePy.app \
       "$ROOT/DNSToggle.app" \
       "$ROOT/DNS.app" \
       "$ROOT/DNSTogglePy.app" \
       "$HOME/Desktop/DNSToggle.app" \
       "$HOME/Desktop/DNS.app" \
       "$HOME/Downloads/DNSToggle.app" \
       "$HOME/Downloads/DNS.app" \
       "$HOME/Applications/DNSToggle.app" \
       "$HOME/Applications/DNS.app" 2>/dev/null || true

# Empty leftover support folder from the old DNS.app identity.
rmdir "$HOME/Library/Application Support/DNS" 2>/dev/null || true

"$LS" -u /Applications/DNS.app 2>/dev/null || true
"$LS" -u "$ROOT/DNSToggle.app" 2>/dev/null || true

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
    <string>2.5.1</string>
    <key>CFBundleVersion</key>
    <string>8</string>
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

SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$SIGN_ID" ]; then
  codesign -s "$SIGN_ID" --force --deep --options runtime "$APP"
else
  codesign -s - --force --deep "$APP"
fi

"$LS" -f "$APP"

# Only unregister / remove paths that are clearly our app — never touch system apps.
"$LS" -dump 2>/dev/null | awk '
  /identifier:[[:space:]]+com\.rahulmasand\.dnstoggle/ { hit=1 }
  hit && /path:/ {
    path=$0; sub(/^[[:space:]]*path:[[:space:]]*/, "", path)
    sub(/[[:space:]]*\(.*$/, "", path)
    if (path ~ /DNSToggle\.app$/ || path ~ /\/DNS\.app$/) print path
    hit=0
  }
' | while IFS= read -r stale; do
  [ -z "$stale" ] && continue
  if [ "$stale" = "/Applications/DNSToggle.app" ]; then
    continue
  fi
  echo "Removing stale DNSToggle copy: $stale"
  "$LS" -u "$stale" 2>/dev/null || true
  rm -rf "$stale" 2>/dev/null || true
done

open "$APP"

echo ""
echo "Installed /Applications/DNSToggle.app (v2.5.1) — only this copy should exist."
echo "REQUIRED once: click Enable password-free switching… to install helper v2 + unbrick agent."
echo "(Your current helper is outdated until you do that.)"
