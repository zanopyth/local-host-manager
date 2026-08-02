# Localhost Manager

A small Windows tray app that scans your machine for running `localhost`
dev servers (npm/node projects), shows their status, resource usage, and
URLs, and lets you start/stop/restart/deploy them individually or in named
groups — with no config file to hand-maintain.

Repo: https://github.com/zanopyth/local-host-manager
Latest release: https://github.com/zanopyth/local-host-manager/releases

## Why this exists

Running several Node/npm projects at once (a frontend, a backend, maybe a
worker) means juggling terminal windows just to know what's up, what's
down, and which port is which. Localhost Manager scans every listening
`localhost` port, figures out which ones are npm dev servers (and *which
project folder* they belong to — even for plain `npm start`, whose command
line gives no hint), and gives you one place to see, control, and now
build/deploy all of them.

## Feature summary

| Feature | What it does |
|---|---|
| Auto-scan | Detects every listening TCP port, matches it to a real project folder |
| Start / Stop / Restart | Per-row buttons, tray menu, or bulk via groups; port-collision check runs before every launch |
| CPU / RAM columns | Live per-process usage right in the grid (CPU off by default, RAM on) |
| Column chooser, resize, reorder | Show/hide the informational columns; drag to resize or reorder; both persist across restarts |
| Pin | Keeps a port's entry (and Restart button) around after it stops, including non-Node processes |
| Custom Name | Rename any row to something meaningful ("API", "Frontend"...) |
| Auto Crash Restart | Per-project opt-in: relaunch automatically on an unexpected exit, capped at 5 attempts / 5 minutes |
| Log viewer | Double-click a row for captured stdout/stderr, without an extra console window |
| Groups | Bundle related projects and start/stop them together |
| Root directory scope | Restrict the whole app to one folder tree |
| Row detail popup | Right-click a row for every column's full value, each with a copy button; Network URLs split one-per-adapter and labeled (Ethernet/Tailscale/VMware/...), with virtual adapters flagged purple |
| Build & Deploy | Per-project build-then-mirror-to-target(s) recipe, run from a live shell view with Stop Deploy |
| Local Domains | Opt-in reverse proxy giving every running project a `*.localhost` address instead of a raw port (browser-only) |
| Web dashboard | Opt-in browser view of the same table with click-to-confirm Stop/Start/Restart, reachable on your LAN/Tailscale with one setup step |
| Themes | Light, Dark, and a Catppuccin-Mocha-inspired Terminal theme |
| System tray | Lives in the tray; closing the window just hides it; icon turns red when anything tracked is down |
| Single-instance guard | Launching a second copy shows a message instead of opening a duplicate window |

See `USER_GUIDE.md` for how to use each of these, `DEVELOPER_GUIDE.md` and
`API.md` for how the code is put together, `INSTALLATION.md` to get it
running, and `KNOWN_ISSUES.md` / `FUTURE_IMPROVEMENTS.md` for the honest
state of things.

## Quick start

1. Download `LocalhostManager.exe` from the GitHub Releases page.
2. Run it. No installer, no admin rights needed.
3. It scans automatically every 4 seconds. Click **Stop**/**Restart** on
   any row, or right-click the tray icon.

## License / ownership

MIT — see `LICENSE` in the repo root.
