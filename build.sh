#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/DNSToggle.app"
BIN="$APP/Contents/MacOS/DNSToggle"
HELPER_SRC="$ROOT/MenuBar/dns-toggle-helper"
INSTALL_SRC="$ROOT/MenuBar/install-helper.sh"

echo "Building DNSToggle..."
cd "$ROOT"
swift build -c release

# Quit old competing apps so two globe icons don't fight.
pkill -9 -f "/Applications/DNS.app/Contents/MacOS/DNS" 2>/dev/null || true
pkill -9 -x DNS 2>/dev/null || true
pkill -9 -f "/Applications/DNSToggle.app/Contents/MacOS/DNSToggle" 2>/dev/null || true
pkill -9 -x DNSToggle 2>/dev/null || true
pkill -f "dns_toggle.py" 2>/dev/null || true

# Keep Spotlight clean — only one app.
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf /Applications/DNS.app "$ROOT/DNSToggle.app" "$ROOT/DNSTogglePy.app"
"$LS" -u /Applications/DNS.app 2>/dev/null || true

rm -rf "$APP" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/DNSToggle" "$BIN"
cp "$HELPER_SRC" "$APP/Contents/Resources/dns-toggle-helper"
# Rewrite install script paths relative to Resources.
cat > "$APP/Contents/Resources/install-helper.sh" <<'HELPER'
#!/bin/bash
# Run as root. Installs the DNS helper and a NOPASSWD sudoers rule for the console user.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/dns-toggle-helper"
DEST="/Library/PrivilegedHelperTools/com.rahulmasand.dns"
SUDOERS="/etc/sudoers.d/dnstoggle"
USER_NAME="$(stat -f '%Su' /dev/console)"

if [ ! -f "$SRC" ]; then
  echo "missing helper at $SRC" >&2
  exit 1
fi

mkdir -p /Library/PrivilegedHelperTools
cp "$SRC" "$DEST"
chown root:wheel "$DEST"
chmod 755 "$DEST"

TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$DEST" > "$TMP"
chmod 440 "$TMP"
if ! /usr/sbin/visudo -cf "$TMP"; then
  rm -f "$TMP"
  echo "sudoers validation failed" >&2
  exit 1
fi
mv "$TMP" "$SUDOERS"
chown root:wheel "$SUDOERS"
chmod 440 "$SUDOERS"

echo "installed helper for $USER_NAME"
HELPER
chmod +x "$BIN" \
         "$APP/Contents/Resources/dns-toggle-helper" \
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
    <string>2.1</string>
    <key>CFBundleVersion</key>
    <string>3</string>
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

echo "Installed and launched /Applications/DNSToggle.app — look for the globe in the menu bar."
