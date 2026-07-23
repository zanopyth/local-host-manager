# Installation

## Requirements

- Windows 10 or 11 (64-bit)
- .NET Framework (Windows Forms) — present by default on any current
  Windows install; nothing to install separately
- No admin rights required to run
- Node.js / npm installed if you want the **Start** button to actually
  launch anything (the app itself has no npm dependency)

## Option 1 — Download the prebuilt exe (recommended)

1. Go to the [Releases page](https://github.com/zanopyth/local-host-manager/releases)
   and download `LocalhostManager.exe` from the latest release.
2. Put it in its own folder — on first run it will create a small
   settings/history store under
   `%LOCALAPPDATA%\LocalhostManager\` (see `DEVELOPER_GUIDE.md`).
3. Double-click to run. Windows SmartScreen may warn about an
   "unrecognized publisher" the first time (the exe isn't code-signed) —
   choose **More info → Run anyway**.
4. Optional but recommended: also grab `LocalhostManager.ico` and
   `LocalhostManager-alert.ico` from the repo and place them **next to**
   the exe. The app looks for them at startup to set the window and tray
   icons (green = healthy, red = something tracked is down); if they're
   missing it silently falls back to a generic icon, so this step is
   cosmetic only.

## Option 2 — Build from source

Requires the [`ps2exe`](https://www.powershellgallery.com/packages/ps2exe)
PowerShell module.

```powershell
# one-time setup
Install-Module ps2exe -Scope CurrentUser -Force

# from the repo folder
Import-Module ps2exe
Invoke-PS2EXE `
  -InputFile "LocalhostManager.ps1" `
  -OutputFile "LocalhostManager.exe" `
  -noConsole `
  -iconFile "LocalhostManager.ico" `
  -title "Localhost Manager" `
  -product "Localhost Manager" `
  -version "1.7.0.0"
```

`-noConsole` is important — without it, every launch pops a visible
PowerShell console window behind the GUI.

## Option 3 — Run the .ps1 directly (no compile)

Useful for development/debugging:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "LocalhostManager.ps1"
```

## Uninstalling / removing all data

The app stores everything under one folder — deleting it removes all
history, settings, custom names, and groups:

```powershell
Remove-Item "$env:LOCALAPPDATA\LocalhostManager" -Recurse -Force
```

Then delete the exe/ps1 wherever you put them. Nothing is written to the
registry or anywhere else on the system.
