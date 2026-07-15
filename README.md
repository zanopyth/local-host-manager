# Localhost Manager

A small Windows tray app that scans your machine for running `localhost` dev
servers (npm/node projects), shows their status, LAN URLs, and lets you
start/stop them individually or in named groups — all without a config file.

## Download

Grab the latest `LocalhostManager.exe` from the
[Releases](../../releases) page and run it. No install needed.

## Features

- Auto-detects running npm/node dev servers by port, recovering each
  project's real working directory even when the command line alone
  doesn't show it (e.g. `npm start`)
- Shows local + LAN URLs so you can share a dev server on your network
- Start/Stop from the grid, the tray icon's right-click menu, or in bulk
  via named **groups** (e.g. "frontend + backend + db")
- Custom names, root-directory scoping, and a tray icon that turns red
  when something in your tracked set goes down
- Runs from the tray — closing the window just hides it

## Building from source

Requires the [`ps2exe`](https://github.com/MScholtes/PS2EXE) PowerShell
module:

```powershell
Install-Module ps2exe -Scope CurrentUser
Import-Module ps2exe
Invoke-PS2EXE -InputFile LocalhostManager.ps1 -OutputFile LocalhostManager.exe `
  -noConsole -iconFile LocalhostManager.ico -title "Localhost Manager"
```

Keep `LocalhostManager.ico` and `LocalhostManager-alert.ico` next to the
compiled `.exe` — they're loaded at runtime for the window/tray icons.
