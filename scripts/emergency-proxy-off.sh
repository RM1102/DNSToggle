#!/bin/bash
# Unbrick the Mac when DNSToggle left a dead IITD system proxy on.
# Prefer the privileged helper; fall back to networksetup with one admin prompt.
set -euo pipefail

HELPER="/Library/PrivilegedHelperTools/com.rahulmasand.dns"

echo "Turning off system HTTP/HTTPS/SOCKS/PAC proxies…"

if [ -x "$HELPER" ] && sudo -n "$HELPER" proxy-off 2>/dev/null; then
  echo "Cleared via privileged helper."
  exit 0
fi

SVC="$(/usr/sbin/networksetup -listallnetworkservices | awk 'NR>1 && $0 !~ /^\*/ && tolower($0) ~ /wi-?fi|airport/ {print; exit}')"
SVC="${SVC:-Wi-Fi}"

CMD=$(cat <<EOF
/usr/sbin/networksetup -setwebproxystate "$SVC" off
/usr/sbin/networksetup -setsecurewebproxystate "$SVC" off
/usr/sbin/networksetup -setsocksfirewallproxystate "$SVC" off
/usr/sbin/networksetup -setautoproxystate "$SVC" off
/usr/sbin/networksetup -setproxybypassdomains "$SVC" Empty
/usr/sbin/networksetup -setwebproxy "$SVC" "" "" off
/usr/sbin/networksetup -setsecurewebproxy "$SVC" "" "" off
/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder
EOF
)

# Escape for AppleScript string
ESC=$(printf '%s' "$CMD" | sed 's/\\/\\\\/g; s/"/\\"/g')
osascript -e "do shell script \"$ESC\" with administrator privileges"
echo "Cleared via admin networksetup on $SVC."
