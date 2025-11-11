# NordVPN Helper

Minimal helper for first-time NordVPN CLI setup on Linux.

- Prereqs: NordVPN Linux app installed, user already logged in or ready with token/callback URL.
- Run: `./nordvpn_helper.sh`
- Flow: confirms login, forces LAN discovery on, allowlists SSH (22) and optional work IP, then guides you to connect (defaults to Ireland; type `fastest` to skip country selection).

Exit the script any time with `Ctrl+C`. Settings persist via `nordvpn` CLI.

