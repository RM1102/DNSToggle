# DNSToggle

Compact macOS menu bar app for Wi‑Fi DNS presets and IIT Delhi institute proxy (proxy22 / proxy62).

## Features

- **DNS presets:** Cloudflare, Google, Quad9, Institute / Automatic
- **Institute Proxy:** Proxy Off · Proxy 22 · Proxy 62 (click again to turn off)
- **Remember on/off:** last intent survives relaunch; never force-connects off-campus
- **Kerberos:** separate Keychain entries for Proxy 22 and Proxy 62 (saving does not turn proxy on)
- **Keepalive:** CGI `Refresh` every 90s; external HTTPS health every ~25s
- **Fail-open:** system proxy cleared on sleep, path-down, failed health, Quit, crash, or hung app
- **Unbrick LaunchAgent:** clears leftover IITD Squid if the app is gone or heartbeat is stale
- **Launch at Login:** opt-in (recommended if you remember proxy on across restarts)
- **Clear VPN & Reset Network:** turns off leftover proxies / VPN residue

## Install

```bash
git clone https://github.com/RM1102/DNSToggle.git
cd DNSToggle
./build.sh
```

Installs and launches `/Applications/DNSToggle.app`. Look for the globe in the menu bar.

**First time:** click **Enable password-free switching…** (admin password once). Connect is blocked until this works — that is intentional so the app can always clear a dead proxy without prompting.

## Usage

1. **Save Kerberos for Proxy 22…** / **Save Kerberos for Proxy 62…** — credentials only; does not connect.
2. Click **Proxy 22** or **Proxy 62** to connect. Click the same button again (or **Proxy Off**) to disconnect.
3. Leave the app running on campus; it refreshes the session and checks open-internet through Squid.
4. Close the lid overnight: proxy is cleared while asleep, then reconnects when campus CGI is reachable after wake.
5. Off campus with “remembered on”: proxy stays **off** until CGI is reachable again.
6. **Unbrick internet now** if anything looks stuck. **Quit** always clears system proxy.

## Emergency unbrick

```bash
./scripts/emergency-proxy-off.sh
```

## Security

- No network listener. Publishing this repo cannot reach your Mac.
- Kerberos passwords live only in the macOS Keychain — never in the repo, logs, or UserDefaults.
- The privileged helper accepts **one allowlisted argument** (DNS presets / proxy22 / proxy62 / proxy-off). sudoers lists those exact commands.
- Install the helper only from an app you built yourself.
- Local log: `~/Library/Logs/DNSToggle.log` (no passwords or session ids).

## Limits

- Health check proves **browser HTTPS through Squid** (Gmail in a browser). Mail.app IMAP does not use the HTTP proxy.
- IITD bypass (`*.iitd.ac.in`, etc.) stays on purpose so campus CGI/mail never go through Squid.

## Notes

- Only `/Applications/DNSToggle.app` should run.
- Proxy login talks to `https://proxyXX.iitd.ac.in/cgi-bin/proxy.cgi` (CSC pattern).
- License: MIT
