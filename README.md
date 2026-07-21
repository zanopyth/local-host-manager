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
- Right-click any row for a compact **Detail** popup — every column's full
  value with a one-click copy button, network addresses broken out one per
  adapter (`Ethernet`, `Tailscale`, `VMware`, ...) and virtual/VM-only
  adapters flagged in purple so you don't mistake one for a real LAN address
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
  -noConsole -iconFile LocalhostManager.ico -title "Localhost Manager" -x64
```

Keep `LocalhostManager.ico` and `LocalhostManager-alert.ico` next to the
compiled `.exe` — they're loaded at runtime for the window/tray icons.

`-x64` is required: the app reads a target process's PEB directly
(`Get-ProcessWorkingDirectory`) to recover its working directory, and a
32-bit build cannot read the memory of 64-bit processes like `node.exe`.
Without `-x64`, every Node/npm dev server silently fails working-directory
detection and gets filtered out by the "Node/npm projects only" checkbox.
