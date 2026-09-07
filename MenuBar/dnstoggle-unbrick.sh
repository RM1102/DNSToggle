#!/bin/bash
# Unbrick IITD Squid when DNSToggle is gone or hung (stale heartbeat).
# Installed root-owned next to the helper. Only clears proxy22/proxy62 hosts.
set -u

HELPER="/Library/PrivilegedHelperTools/com.rahulmasand.dns"
HEARTBEAT="${HOME}/Library/Application Support/DNSToggle/heartbeat"
STALE_SECS=40

iitd_proxy_present() {
  local svc web
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    web="$(/usr/sbin/networksetup -getwebproxy "$svc" 2>/dev/null || true)"
    printf '%s' "$web" | grep -qi 'enabled: yes' || continue
    if printf '%s' "$web" | grep -Eq 'proxy(22|62)\.iitd\.ac\.in'; then
      return 0
    fi
  done < <(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | awk 'NR>1 && $0 !~ /^\*/')
  return 1
}

should_clear() {
  if ! pgrep -x DNSToggle >/dev/null 2>&1; then
    return 0
  fi
  if [ ! -f "$HEARTBEAT" ]; then
    # App running but never wrote a lease — wait until next pulse after upgrade.
    return 1
  fi
  local stamp now age
  stamp="$(tr -cd '0-9' < "$HEARTBEAT" | head -c 20)"
  [ -n "$stamp" ] || return 0
  now="$(date +%s)"
  age=$((now - stamp))
  [ "$age" -gt "$STALE_SECS" ]
}

iitd_proxy_present || exit 0
should_clear || exit 0

if [ -x "$HELPER" ]; then
  /usr/bin/sudo -n "$HELPER" proxy-off >/dev/null 2>&1 || true
fi
