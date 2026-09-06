#!/bin/bash
# Installs the DNS helper + passwordless sudo rule. Must run as root.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root" >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)/dns-toggle-helper"
if [ ! -f "$SRC" ]; then
  echo "Missing helper at $SRC" >&2
  exit 1
fi

USER_NAME="$(stat -f '%Su' /dev/console)"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ] || [ "$USER_NAME" = "loginwindow" ]; then
  USER_NAME="${SUDO_USER:-rahulmasand}"
fi

mkdir -p /usr/local/libexec
cp "$SRC" /usr/local/libexec/dns-toggle-helper
chown root:wheel /usr/local/libexec/dns-toggle-helper
chmod 755 /usr/local/libexec/dns-toggle-helper

SUDOERS="/etc/sudoers.d/dns-toggle"
cat > "$SUDOERS" <<EOF
${USER_NAME} ALL=(root) NOPASSWD: /usr/local/libexec/dns-toggle-helper
EOF
chown root:wheel "$SUDOERS"
chmod 440 "$SUDOERS"

if ! /usr/sbin/visudo -cf "$SUDOERS"; then
  rm -f "$SUDOERS"
  echo "sudoers validation failed" >&2
  exit 1
fi

echo "Installed passwordless DNS helper for ${USER_NAME}"
