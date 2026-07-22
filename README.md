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
- **Web dashboard** (new in v1.6, opt-in — off until you enable it from the
  **Dashboard** menu): a browser view of the same table at
  `http://localhost:3199` (port configurable), with click-to-confirm
  Stop/Start/Restart, per-adapter clickable LAN/Tailscale links, and a
  live status pill in the toolbar showing whether it's running
- Single-instance protection — launching the app while it's already
  running just shows a message instead of opening a duplicate window

## Web dashboard

Enable it from the **Dashboard** menu — pick a port (default `3199`) and
toggle it on. By default it only binds to `localhost`/`127.0.0.1`, so it's
reachable from this PC even without doing anything else.

To reach it from your **phone or another device on the same LAN**, or over
**Tailscale**, run this once as Administrator, then restart the app:

```powershell
netsh http add urlacl url=http://+:3199/ user=Everyone
New-NetFirewallRule -DisplayName "Localhost Manager Dashboard" -Direction Inbound -Protocol TCP -LocalPort 3199 -Action Allow
```

Without this one-time step, the LAN/Tailscale addresses will show up in the
dashboard's own address list but nothing will actually be listening there —
connections from another device will just time out. The dashboard page
itself has a "Remote access tips" panel with this same info, plus a note on
using Tailscale subnet routes if you want to reach it from outside your LAN
without installing Tailscale on every device. If your phone still can't
connect after the elevated step, check whether your Wi-Fi has AP/client
isolation enabled (common on guest networks) — that blocks device-to-device
traffic regardless of firewall/port settings.

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
