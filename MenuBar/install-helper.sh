#!/bin/bash
# Run as root. Installs the DNS helper, explicit NOPASSWD sudoers, and unbrick LaunchAgent.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/dns-toggle-helper"
UNBRICK_SRC="$(cd "$(dirname "$0")" && pwd)/dnstoggle-unbrick.sh"
DEST="/Library/PrivilegedHelperTools/com.rahulmasand.dns"
UNBRICK_DEST="/Library/PrivilegedHelperTools/com.rahulmasand.dnstoggle-unbrick"
SUDOERS="/etc/sudoers.d/dnstoggle"
PLIST="/Library/LaunchAgents/com.rahulmasand.dnstoggle.unbrick.plist"
USER_NAME="$(stat -f '%Su' /dev/console)"
USER_UID="$(id -u "$USER_NAME")"

if [ ! -f "$SRC" ]; then
  echo "missing helper at $SRC" >&2
  exit 1
fi
if [ ! -f "$UNBRICK_SRC" ]; then
  echo "missing unbrick script at $UNBRICK_SRC" >&2
  exit 1
fi

# Refuse to install from a random writable path (must live under DNSToggle.app Resources).
if [[ "$(cd "$(dirname "$0")" && pwd)" != /Applications/DNSToggle.app/Contents/Resources ]]; then
  echo "refusing install outside /Applications/DNSToggle.app/Contents/Resources" >&2
  exit 1
fi

mkdir -p /Library/PrivilegedHelperTools
cp "$SRC" "$DEST"
chown root:wheel "$DEST"
chmod 755 "$DEST"

cp "$UNBRICK_SRC" "$UNBRICK_DEST"
chown root:wheel "$UNBRICK_DEST"
chmod 755 "$UNBRICK_DEST"

# Explicit command list — not "any argument to helper".
TMP="$(mktemp)"
{
  printf '%s ALL=(root) NOPASSWD: %s version\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s ping\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s cloudflare\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s google\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s quad9\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s opendns\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s adguard\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s controld\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s mullvad\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s auto\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s clear\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s flush\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s proxy-on\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s proxy62-on\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s proxy22-on\n' "$USER_NAME" "$DEST"
  printf '%s ALL=(root) NOPASSWD: %s proxy-off\n' "$USER_NAME" "$DEST"
} > "$TMP"
chmod 440 "$TMP"
if ! /usr/sbin/visudo -cf "$TMP"; then
  rm -f "$TMP"
  echo "sudoers validation failed" >&2
  exit 1
fi
mv "$TMP" "$SUDOERS"
chown root:wheel "$SUDOERS"
chmod 440 "$SUDOERS"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rahulmasand.dnstoggle.unbrick</string>
    <key>ProgramArguments</key>
    <array>
        <string>${UNBRICK_DEST}</string>
    </array>
    <key>StartInterval</key>
    <integer>15</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/dnstoggle-unbrick.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/dnstoggle-unbrick.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout "gui/${USER_UID}/com.rahulmasand.dnstoggle.unbrick" 2>/dev/null || true
launchctl bootstrap "gui/${USER_UID}" "$PLIST" 2>/dev/null || true
launchctl enable "gui/${USER_UID}/com.rahulmasand.dnstoggle.unbrick" 2>/dev/null || true
launchctl kickstart -k "gui/${USER_UID}/com.rahulmasand.dnstoggle.unbrick" 2>/dev/null || true

VER="$("$DEST" version 2>/dev/null || true)"
echo "installed helper v${VER:-?} + unbrick agent for $USER_NAME"
