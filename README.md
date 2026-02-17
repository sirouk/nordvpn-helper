# NordVPN Helper

Minimal helper for first-time NordVPN CLI setup on Linux.

- Prereqs: NordVPN Linux app installed, user already logged in or ready with token/callback URL.
- Run: `./nordvpn_helper.sh`
- Flow: confirms login, forces LAN discovery on, allowlists SSH (22) and optional work IP, then guides you to connect with one of:
  - fastest server,
  - country-based server (defaults to Ireland),
  - dedicated-IP server by server id (for example: `ie214`, `us123`).
- Dedicated mode can optionally verify your expected public IP after connect.
- Dedicated mode auto-suggests a previous server id when it can detect one from NordVPN state.

Exit the script any time with `Ctrl+C`. Settings persist via `nordvpn` CLI.
