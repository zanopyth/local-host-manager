# Localhost Manager

A small Windows tray app that scans your machine for running `localhost`
dev servers (npm/node projects), shows their status and URLs, and lets you
start/stop them individually or in named groups — with no config file to
hand-maintain.

Repo: https://github.com/zanopyth/local-host-manager
Latest release: https://github.com/zanopyth/local-host-manager/releases

## Why this exists

Running several Node/npm projects at once (a frontend, a backend, maybe a
worker) means juggling terminal windows just to know what's up, what's
down, and which port is which. Localhost Manager scans every listening
`localhost` port, figures out which ones are npm dev servers (and *which
project folder* they belong to — even for plain `npm start`, whose command
line gives no hint), and gives you one place to see and control all of
them.

## Feature summary

| Feature | What it does |
|---|---|
| Auto-scan | Detects every listening TCP port, matches it to a real project folder |
| Start / Stop | Per-row buttons, tray menu, or bulk via groups |
| Custom Name | Rename any row to something meaningful ("API", "Frontend"...) |
| Groups | Bundle related projects and start/stop them together |
| Show Groups toggle | Collapse the view to just your curated, grouped projects |
| Root directory scope | Restrict the whole app to one folder tree |
| System tray | Lives in the tray; closing the window just hides it |
| Status icon | Tray icon turns red when anything tracked is down |

See `USER_GUIDE.md` for how to use each of these, `DEVELOPER_GUIDE.md` and
`API.md` for how the code is put together, `INSTALLATION.md` to get it
running, and `KNOWN_ISSUES.md` / `FUTURE_IMPROVEMENTS.md` for the honest
state of things.

## Quick start

1. Download `LocalhostManager.exe` from the GitHub Releases page.
2. Run it. No installer, no admin rights needed.
3. It scans automatically every 4 seconds. Click **Stop**/**Start** on any
   row, or right-click the tray icon.

## License / ownership

Personal project, not currently under an open-source license — treat the
private repo as source-available for your own use.
