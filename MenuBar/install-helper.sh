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
