# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [1.7.0] - 2026-07-23

### Added
- **System tab** (Settings ▸ Preferences ▸ "Show system-owned ports"):
  read-only view of ports owned by OS processes (System, svchost, lsass,
  ...) — most commonly the kernel http.sys listener behind a .NET
  HttpListener, which reports as PID 4 "System" rather than the app that
  actually registered it. This is how the app's own web dashboard port
  could look silently "taken" with no visible owner. Grayed out until
  enabled; never Start/Stop/Restart-able
- **Pin**: a per-row pin toggle on Live/History keeps a port's entry
  listed (and restartable) after it stops, including non-Node processes,
  which previously were never remembered once they exited. A pinned port
  also stays visible through the Dev Servers Only filter
- Manage Groups: "Pin all ports in this group" checkbox bulk-pins every
  port on record for the group's projects when you hit Save Group
- Start/Restart can now bring back non-npm processes: the background
  poller captures the exact command line a process was launched with
  (e.g. `python -m http.server 8792`) straight out of its own memory, and
  replays it when there's no `package.json` to run against instead of
  always guessing npm
- Row Detail popup now shows Pinned status and the captured Command (when
  known)

### Changed
- Right-click "Detail..." now opens the detail popup directly instead of
  going through a single-item context menu (which always looked broken —
  empty icon gutter, box wider than the text needed)

### Fixed
- Start/Restart no longer silently falls back to `npm run start` (and
  crashing with an ENOENT) when a port has no `package.json` and no known
  launch command — shows a clear "No Known Start Command" message instead

## [1.6.1] - 2026-07-23

### Added
- **Manage Groups**: "Show all listening ports" checkbox reveals every open
  port (not just Node/dev-server ones), so non-Node processes (Python,
  Docker, etc.) can be added to a group too
- Rounded corners on all dropdown/context menus (File, Settings, Groups
  picker, row right-click menu, tray menu)

### Changed
- Toolbar redesign: Start All/Stop All regrouped into a compact two-row
  cluster next to Refresh; the Use Groups/Dev Servers Only toggles moved to
  a fixed column and stay visible (grayed out, not hidden) when groups are
  off, so the layout no longer shifts
- Dashboard status indicator redesigned from a labeled pill to a small
  circular badge — details (port, URL, error) now live in the tooltip

### Fixed
- Start All/Stop All now correctly act on groups containing non-Node ports
  (previously hardcoded to Node-only detection, so such a group would save
  fine but silently do nothing)
- Disabled buttons (e.g. Start All/Stop All when "Use Groups" is off) now
  render visibly grayed out instead of looking identical to enabled ones
- DataGridView no longer leaks stray vertical column-divider lines under
  Windows 11's visual style
- Dashboard status dot's center dot is now pixel-accurate centered (was off
  by rounding)

## [1.6.0] - 2026-07-22

### Added
- **Web dashboard** (Dashboard menu, off by default): browser view of the
  table at a configurable port (default 3199) with click-to-confirm
  Stop/Start/Restart, per-adapter clickable LAN/Tailscale links, app icon as
  favicon, and a live status pill in the toolbar
- **Single-instance guard**: launching a second copy now shows a message
  instead of opening a duplicate window

### Changed
- Toolbar layout refresh: status pill and Scope repositioned, "last
  refreshed" simplified to a footer clock

### Fixed
- Toolbar controls anchored to the right edge (Scope, the old status label)
  were computing their position against the toolbar's un-docked default
  width instead of its real width, landing off-screen

## [1.5.2] - 2026-07-15

### Added
- Multi-group ordering with separators
- Pill toggle switches replacing checkboxes
- In-app Terminal and Log Viewer dialogs, with managed-process log capture
- Tray alert icon state

### Fixed
- The periodic refresh timer called `Get-NetTCPConnection`/
  `Get-NetIPAddress` synchronously on the UI thread; being WMI-backed, these
  could take 200ms-1s+ and would freeze the window (most visibly, dragging
  the title bar would stutter every ~4 seconds). The scan now runs in a
  background runspace polling into a synchronized cache, so the UI timer
  just reads the cache instead.

## [1.5.1] - 2026-07-15

Initial release.

### Added
- Auto-detects running npm/node dev servers by port
- Local + LAN URLs for sharing a dev server on your network
- Start/Stop from the grid, tray menu, or in bulk via named groups
- Custom names, root-directory scoping, red tray icon on failure
- Lives in the tray — closing the window just hides it

[1.7.0]: https://github.com/zanopyth/local-host-manager/releases/tag/v1.7.0
[1.6.1]: https://github.com/zanopyth/local-host-manager/releases/tag/v1.6.1
[1.6.0]: https://github.com/zanopyth/local-host-manager/releases/tag/v1.6.0
[1.5.2]: https://github.com/zanopyth/local-host-manager/releases/tag/v1.5.2
[1.5.1]: https://github.com/zanopyth/local-host-manager/releases/tag/v1.5.1
