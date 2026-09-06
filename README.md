# DNSToggle

Compact macOS menu bar app for Wi‑Fi DNS presets and IIT Delhi institute proxy (proxy22 / proxy62).

## Features

- **DNS presets:** Cloudflare, Google, Quad9, Institute / Automatic
- **Institute Proxy:** one-click Proxy 22 or Proxy 62
- **Kerberos:** saved in Apple Keychain (`com.rahulmasand.dns.iitd-proxy`)
- **Keepalive:** CGI `Refresh` every 60s so the CSC session does not idle out
- **Launch at Login:** enabled on first run via `SMAppService`
- **Clear VPN & Reset Network:** turns off leftover proxies / VPN residue

## Install

```bash
cd ~/Developer/DNSToggle
./build.sh
```

Installs and launches `/Applications/DNSToggle.app`. Look for the globe in the menu bar.

First time you change DNS or enable proxy, macOS may ask for your password (or the bundled privileged helper installs for password-free switching).

## Usage

1. **Save Kerberos…** — enter your IITD userid + password (Keychain only).
2. Click **Proxy 22** (BTech) or **Proxy 62** (dual / MTech).
3. Leave the app running; it refreshes the proxy session automatically.
4. **Log out proxy** clears system proxy + CGI session.
5. Toggle **Launch at Login** if you want it after reboot.

## Notes

- Only one of `/Applications/DNSToggle.app` should run (build script quits old `DNS.app`).
- Proxy login talks to `https://proxyXX.iitd.ac.in/cgi-bin/proxy.cgi` (CSC pattern).
- Password is never stored in the repo or UserDefaults — only Keychain.
