# Internal Function Reference

This app has no external/network API — it's a single-process desktop
tool (though several features open their own local `HttpListener`s; see
"Web dashboard and Local Domains" below). This document is a curated
reference for the non-obvious functions in `LocalhostManager.ps1` — what
they take, what they return, and what they touch. It doesn't try to cover
every function in a multi-thousand-line file, only the ones worth knowing
before you change adjacent code.

## Process / filesystem inspection

### `Get-ProcessWorkingDirectory -ProcId <int>`
Returns the real working directory of an arbitrary running process by
reading its PEB, or `$null` if the read fails for any reason. See
`DEVELOPER_GUIDE.md` for how. Uses an inline C# type (`Add-Type` near the
top of the file) for the `NtQueryInformationProcess`/`ReadProcessMemory`
P/Invoke calls.

### `Get-LiveListeners`
No parameters. Returns the most recent snapshot from `$script:LiveCache`
(a `[hashtable]::Synchronized` shared with the background poller runspace
— see "Background polling" in `DEVELOPER_GUIDE.md`): a hashtable keyed by
port (string) → `@{ Port; ProcId; ProcessName; LocalAddr; ProjectPath;
IsNode; CpuPercent; MemMB; CommandLine; IsSystem }`. This call itself
never touches the network/WMI — the actual scan, process resolution, PEB
read, and CPU/RAM sampling happen off the UI thread in
`$script:BackgroundPollScript`.

### `Get-LanIPv4Addresses`
No parameters. Returns the background poller's most recent list of
non-loopback, non-APIPA IPv4 addresses bound to this machine (LAN,
VPN/Tailscale, virtual adapters — anything), read from
`$script:LiveCache.LanIps`. Each entry is a `[PSCustomObject]@{ IPAddress;
InterfaceAlias }` — classification into a display label happens later, in
`Build-Rows`, via `Get-NetworkInterfaceLabel`. Used to build the "Network
URL(s)" column and the per-adapter rows in the row Detail popup.

### `Get-NetworkInterfaceLabel -InterfaceAlias <string>`
Classifies an adapter name into `[PSCustomObject]@{ Label; IsVirtual;
SortRank }` — e.g. `Ethernet`/`Wi-Fi` (SortRank 0, real), `Tailscale`
(SortRank 1, real but VPN), or `VMware`/`Hyper-V`/`VirtualBox`/`Docker`
(SortRank 2, `IsVirtual = $true`). Falls back to the raw `InterfaceAlias`
text for anything unrecognized. Used by `Build-Rows` to label, sort, and
flag each Network URL entry, and by `Show-RowDetail` to purple-tint rows
for virtual/VM-only adapters.

### `Get-PortListenerInfo -Port <int>`
Fresh, synchronous, single-port check (not read from `$script:LiveCache`,
which can lag by up to one poll interval) — used right before a launch,
by `Test-PortCollision`, to see exactly what's on a port *at that
instant*. Returns process/path info or `$null` if nothing's listening.

### `Stop-BackgroundPoller`
No parameters, no return value. Signals the background poller runspace to
stop (`$script:LiveCache.StopRequested = $true`), then stops/disposes the
`PowerShell` instance and closes the runspace. Called from `FormClosing`
when the app is actually exiting (not minimizing to tray).

## Row building / filtering

### `Build-Rows -OnlyNode <bool> -RootDir <string>`
The core "what should be displayed" function. Merges `Get-LiveListeners`
output with `Load-History`, so ports that aren't currently running but
were previously seen (or Pinned) still show up as `OFF`/`CRASHED` rows
with a known restart path. Falls back to a port's last known-good
path/command line when a live PEB read comes back empty for a
previously-resolved port (see `DEVELOPER_GUIDE.md`'s PEB section).
Applies the `OnlyNode`/`RootDir` filters (Pinned and Auto-Restart-enabled
ports bypass `OnlyNode`), attaches `CustomName` via `Get-CustomNameKey`,
and persists any newly-seen/Pinned/Auto-Restart project back to
`history.json`. Returns an array of `[PSCustomObject]` with: `Status,
Port, CustomName, ProcessName, ProcId, Cpu, Mem, LocalUrl, LanUrls,
LanEntries, ProjectPath, Action, HasLog, Pinned, AutoRestart,
CommandLine`, sorted by port number. `Status` is `ON`, `OFF`, or
`CRASHED` (an unattended exit, as opposed to one the user triggered).
`LanEntries` is the structured, per-adapter form behind `LanUrls` — an
array of `[PSCustomObject]@{ Label; Url; IsVirtual; SortRank }`, already
sorted real-adapters-first; empty for non-`ON` rows and for rows whose
listener only binds to `127.0.0.1`.

Called with different arguments by different parts of the UI — see
`DEVELOPER_GUIDE.md` → "The scanning pipeline".

### `Get-DisplayRows`
No parameters (reads the toolbar's live controls/`$script:` state
directly). The actual per-refresh entry point wrapping `Build-Rows`:
when **Use Groups** is on with a selection, calls `Build-Rows -OnlyNode
$false -RootDir ''` and narrows via `Get-GroupRowsOrdered` instead (group
selection overrides the Node-only/root-dir filters entirely); otherwise
calls `Build-Rows` with the toolbar's current checkbox/scope values.
Returns `@({ Row; Group })` pairs — `Group` is `$null` for an ungrouped
row, otherwise the group name, used to decide where a separator row goes.

### `Get-DisplayRowsSplit`
No parameters. Calls `Get-DisplayRows` once, then also calls
`Publish-DashboardRows` and `Update-ProxyRouteMap` with that same result
(so the web dashboard and Local Domains proxy stay in sync with exactly
what the grid is about to show), and splits the result into `@{ Live;
History; System }` by `Status`. `System` is only populated when
`$script:Settings.ShowSystemPorts` is on.

### `Get-GroupRowsOrdered -Rows <array> -GroupNames <string[]>`
Reorders/filters a `Build-Rows` result down to just the given groups,
tagging each row with its group name for separator-row placement.

### `Test-PathUnderRoot -Path <string> -Root <string>`
Case-insensitive path-prefix test used by the root-directory scope
feature. Returns `$true` if `Root` is empty (no restriction configured).

### `Get-CustomNameKey -ProjectPath <string> -Port <string>`
The lookup key used for the custom-names dictionary: the normalized
project path if known, otherwise `"port:<port>"` as a fallback so a
custom name can still be set on a port whose path couldn't be resolved.

### `Get-NormalizedPath -Path <string>`
Lowercases and trims a trailing backslash — the canonical form used
everywhere paths are compared (custom names, group membership, deploy
recipes, auto-restart config).

## Persistence (all under `%LOCALAPPDATA%\LocalhostManager\`)

Each of these follows the same `Load-X` / `Save-X` pattern: `Load-X`
reads the JSON file into a hashtable (returning `@{}` if the file is
missing or unparseable — never throws), `Save-X` writes a hashtable back
out, creating the directory if needed.

| Pair | Backing file |
|---|---|
| `Load-History` / `Save-History` | `history.json` |
| `Load-Settings` / `Save-Settings` | `settings.json` |
| `Load-CustomNames` / `Save-CustomNames` | `customnames.json` |
| `Load-Groups` / `Save-Groups` | `groups.json` |
| `Load-DeployDefs` / `Save-DeployDefs` | `deploydefs.json` |

`Load-Settings` additionally applies defaults (theme, column
visibility/order/fill-weights, `OnlyNode`, `RootDir`, `ShowGroups`,
dashboard/proxy settings, startup options, ...) and back-fills fields for
settings files written before each existed.

### Column layout persistence
- `Get-DefaultColumnVisibility` / `Get-DefaultColumnFillWeights` /
  `Get-DefaultColumnOrder` — fresh-install defaults for the column
  chooser, Fill-mode weights, and left-to-right order, respectively.
- `Get-NormalizedColumnOrder -Order <string[]>` — forces the Restart
  (`Log`) and Stop/Start (`Action`) columns to always be the last two
  entries, applied both when persisting a reorder and when restoring one,
  since WinForms has no per-column "don't let this be reordered" flag.
- `Save-ColumnLayout` — writes current widths/order to `settings.json`.
  Only ever called from a debounced `Timer` (`Schedule-ColumnLayoutSave`),
  never directly from a `ColumnWidthChanged`/`ColumnDisplayIndexChanged`
  handler — see the reentrancy gotchas in `DEVELOPER_GUIDE.md`.
- `Update-ColumnVisibility` / `Update-ColumnLayout` — apply
  `$script:Settings` onto the live grid columns (visibility, width,
  order) on startup and after a settings change.

## Actions (start/stop/restart)

### `Get-NpmRunScript -ProjectPath <string>`
Picks `start` or `dev` from the project's `package.json` (whichever
actually exists as a script), falling back to `start` — used instead of
always hardcoding `npm start`, which fails outright for workspace
packages that only define `dev`.

### `Start-ProjectAtPath -ProjectPath <string> -CommandLine <string>`
For an npm project (has `package.json`), runs `npm run <script>` via
`Get-NpmRunScript`. For anything else, replays `CommandLine` — the exact
OS argv this app previously captured for that process (from the
background poller). Runs under a redirected, non-console `cmd.exe`, with
output captured line-by-line into that project's managed log (see
`Show-LogViewer`) via `Register-ObjectEvent`, not a raw
`.Add_OutputDataReceived` (which fires on a ThreadPool thread and would
corrupt this single-threaded runspace). On an unattended exit (not
`StoppedByUser`), triggers `Invoke-CrashAutoRestart` if that project has
Auto Crash Restart enabled. Returns `$true`/`$false` for whether the
launch itself started successfully.

### `Test-ProjectStartable -ProjectPath <string> -CommandLine <string>`
Mirrors the check `Start-ProjectAtPath` makes internally, so the UI can
show a specific "No Known Start Command" message up front instead of a
generic failure after already trying.

### `Test-PortCollision -ProjectPath <string> -Port <int> -Label <string>`
Runs immediately before a desktop-triggered Start/Restart. If the target
port is already held by something, shows a confirm dialog (worded
differently depending on whether the squatter looks like the same
project or something unrelated) and, if confirmed, `taskkill /T /F`s it.
Returns `$true` if it's fine to proceed with the launch, `$false` if the
caller should not start it. Not wired into `Start-ProjectAtPath` itself —
that function is also the web dashboard's start/restart path, and a
blocking `MessageBox` from a remote browser click would hang the desktop
app waiting for someone at the keyboard.

### `Stop-ProjectById -ProcId <int> -ProjectPath <string>`
`taskkill /PID <id> /T /F` (whole child process tree) on the given PID,
with a bounded wait (`Wait-ProcessExitUiResponsive`) so a slow/stuck
`taskkill` never blocks the UI thread, plus a safety-net direct
`Stop-Process` if a detached descendant survives the tree-kill. Returns
`$true`/`$false`.

### `Invoke-ToggleAction -data <row object>` / `Invoke-Restart -data <row object>`
The single-row Stop/Start and Restart actions wired to the grid's Action
and Log (Restart) columns and every per-project tray menu item. Both show
a confirm dialog before stopping, run `Test-PortCollision` before
starting, keep the window responsive during the wait via
`Wait-UiResponsive`/`Wait-ProcessExitUiResponsive` (`Application.DoEvents`
in a bounded loop, not a plain blocking sleep), and guard against a
double-click re-entering mid-action via `$script:ActionBusy`.

### `Invoke-TogglePin -data <row object>`
Flips `Pinned` in that port's `history.json` record (merging onto the
existing entry so `AutoRestart` isn't clobbered), then defers a
`Refresh-Grid` via `BeginInvoke` — see the reentrancy gotchas in
`DEVELOPER_GUIDE.md` for why it can't just call `Refresh-Grid` inline.

### `Get-AutoRestartConfig -ProjectPath <string>`
Returns `[PSCustomObject]@{ Enabled; CommandLine }` for a project by
scanning every `history.json` entry for a path match (a just-crashed
process is no longer listening on a port, so this can't do a direct port
lookup like `Invoke-TogglePin` does).

### `Invoke-CrashAutoRestart -ProjectPath <string> -CommandLine <string> -Label <string>`
Called from `Start-ProjectAtPath`'s exit handler when a project with
Auto Crash Restart enabled exits unexpectedly. Tracks attempts in
`$script:AutoRestartAttempts` (keyed by normalized path, kept separate
from the process's own managed-process entry since that gets replaced
outright on every restart). Capped at `$script:AutoRestartMaxAttempts`
(5) within `$script:AutoRestartWindowMinutes` (5); past the cap, logs and
shows a balloon instead of retrying, if
`$script:Settings.CrashNotifications` is on.

## Build & Deploy

### `Show-DeployConfigDialog -ProjectPath <string> -Label <string>`
Add/edit the recipe attached to `$ProjectPath` (`deploydefs.json`, keyed
by normalized path): a working folder the build command runs in
(independently editable from `$ProjectPath` — e.g. a server's *tracked
port* can have a recipe whose build actually runs in a separate frontend
folder), the build command itself, the source folder to copy from, and
any number of target folders. Returns the saved config hashtable, or
`$null` if cancelled. Never runs anything itself.

### `Show-DeployRunDialog -ProjectPath <string> -Label <string> -Port <string> -Config <hashtable>`
Runs the build command then mirrors the source folder into every target
via `robocopy /MIR` (each target unconditional once the build succeeds,
so one unreachable target doesn't skip the others) under a `cmd.exe /k`
session whose output streams live into a textbox — the session stays
open afterward as a real interactive shell (typed lines go to its stdin)
instead of exiting the moment the scripted part finishes. **Run Again**
re-runs the same recipe; **Stop Deploy** hard-kills the whole `cmd.exe`
process tree (`taskkill /T /F`, same mechanism as `Stop-ProjectById`) —
not a real `CTRL_C_EVENT`, since this session has no console of its own
to send one from and a soft signal risks some build tools swallowing it.

### `Invoke-DeployForProject -ProjectPath <string> -Label <string> -Port <string>`
Entry point for both the row-detail **Deploy** button and the Deploy
Manager's **Deploy** button. Looks up an existing recipe; if none exists,
prompts via `Show-DeployConfigDialog` first, then runs
`Show-DeployRunDialog`. (The row-detail **C-Deploy** button, and the
Deploy Manager's **Configure...** button, call `Show-DeployConfigDialog`
directly instead, and never run anything.)

### `Show-DeployManagerDialog`
No parameters. The toolbar Deploy button's picker — every tracked port
(live + history, independent of the main window's own group/root-dir
scoping), filterable by group or port range, with **Deploy** and
**Configure...** buttons for the selected row.

## Web dashboard and Local Domains (each its own `HttpListener`)

Both are opt-in, each running on its own background runspace — see
`DEVELOPER_GUIDE.md` for the shared architecture. Neither is a
general-purpose "API" meant for external callers; the dashboard's routes
exist only to serve its own page.

### `Start-WebDashboard -Port <int>` / `Stop-WebDashboard` / `Restart-WebDashboard -Port <int>`
Starts/stops the dashboard's `HttpListener` runspace. Routes: `GET /`
(the page itself, from `Get-DashboardHtml`), `GET /api/rows`, `GET
/api/meta`, `POST /api/stop|start|restart` (each enqueues an action the
UI-thread `$script:DashboardActionTimer` drains via
`Invoke-DashboardAction`, so the actual Stop/Start/Restart still runs on
the UI thread, never inside the listener's own request handler).

### `Publish-DashboardRows -Display <array>`
Called every refresh cycle (from `Get-DisplayRowsSplit`) to push the
current row set into `$script:DashboardCache` for `/api/rows` to serve —
cheap, and "a few seconds stale" is fine for a table nobody but a local
browser tab reads.

### `Get-DashboardAddresses -Port <int>`
Every address the dashboard is reachable at right now (localhost, plus
one per real/Tailscale LAN adapter) — shown in the dashboard's own
"remote access tips" panel and the Dashboard dialog.

### `Invoke-DashboardAction -Action <hashtable>`
Runs one queued dashboard action (`stop`/`start`/`restart`, matching
`Invoke-ToggleAction`/`Invoke-Restart`'s underlying calls) and returns a
result the listener relays back to the browser. Deliberately doesn't use
`Test-PortCollision` (a blocking `MessageBox` would hang the desktop app
waiting on nobody, since the click came from a remote browser).

### `Start-ProxyServer -Port <int>` / `Stop-ProxyServer` / `Restart-ProxyServer -Port <int>`
Starts/stops the Local Domains reverse proxy's `HttpListener` runspace,
bound wildcard (`http://+:<port>/`, needing the one-time `netsh` grant)
so it can route by `Host` header. Request handling runs against a small
`RunspacePool` (`$script:ProxyHandleRequestScript`) rather than a
synchronous accept loop, since a single page load fires several parallel
requests.

### `Get-ProxySlug -Label <string> -Port <string>`
DNS-label-safe hostname piece: lowercase, non-alphanumeric runs collapsed
to one hyphen, trimmed; falls back to `port-<n>` if that leaves nothing.

### `Update-ProxyRouteMap -Display <array>`
Rebuilt every refresh cycle from whatever's currently `ON`. Slug is
derived from each row's Custom Name (or folder name if unset) via
`Get-ProxySlug`; a collision with an already-used slug gets the port
appended so it stays unique instead of silently shadowing the first.

### `Get-ProxyUrlForPort -Port <string>`
Reverse lookup (port → slug) used by the row Detail popup's "Local
Domain" field — the route map itself is keyed by slug, but the grid only
ever knows a row's port.

## Logging

### `Show-LogViewer -ProjectPath <string> -Title <string>`
Opens the captured stdout/stderr for a project this app itself launched
(only available while `$script:ManagedProcesses` has a live entry for
it — see `Start-ProjectAtPath`). Backed by an in-memory ring buffer per
process plus a mirrored on-disk file (`Get-ProjectLogFilePath`/
`Save-ProjectLogLine`, under `logs\`) so the app restarting doesn't lose
scrollback the in-memory copy would.

### `Write-AppErrorLog -Context <string> -Exception <Exception> [-Extra <string>] [-Level Error|Warning]`
Appends a timestamped entry to `logs\app-error.log`, capped at a fixed
line count. Wired to `[Application]::add_ThreadException` and
`[AppDomain]::CurrentDomain.add_UnhandledException` at startup so most
unhandled UI-thread exceptions get logged automatically, plus called
directly at specific failure points (a failed launch, a taskkill
timeout, ...) for better context than a bare unhandled-exception trace.

## GUI wiring (not really an "API", but referenced elsewhere in these docs)

- `Refresh-Grid` / `Render-Grid -Grid <control> -Display <array>` —
  rebuild the DataGridViews from `Get-DisplayRowsSplit`; no-op while any
  grid has a cell mid-edit.
- `Invoke-PeriodicRefresh` — the 4-second `Timer` tick handler; only
  repaints a grid whose `Get-DisplayRowsSignature` actually changed, to
  avoid flickering/resetting selection every tick.
- `Update-GroupsVisibility` — shows/hides the group toolbar row and
  resizes the grid to fill the freed/reclaimed space.
- `Update-TrayIcon` — recomputes the tray icon color/tooltip (green/red,
  now also reflecting `CRASHED` rows).
- `Build-TrayMenuItems` — rebuilds the tray context menu; wired to the
  menu's `Opening` event, not the refresh timer.
- `Get-KnownProjects` — every distinct project the app has ever seen,
  for populating the Manage Groups checklist.
- `Show-SettingsDialog` / `Show-ManageGroupsDialog` — modal dialogs
  (Settings is tabbed: General/Appearance/Startup/Diagnostics).
- `Show-RowDetail -Data <row object> -ScreenPoint <Point>` — the compact
  "sticky note" popup opened via right-click → **Detail...** on a grid
  row. Renders most fields as read-only `Label` rows with a copy-icon
  button each; the Auto-Restart field is the one exception, rendered as
  a real `CheckBox` wired to `Invoke-ToggleAutoRestart`, positioned first
  in the field list. Expands `LanEntries` into one row per network
  address, tints a row purple when `IsVirtual` is set, and adds a Local
  Domain row when the proxy is running for that port. Opens at
  `ScreenPoint` (real screen coordinates, not grid-relative — the
  `CellMouseDown` handler uses `[Cursor]::Position` rather than the
  event's own `e.X`/`e.Y`, which are cell-relative), clamped to stay
  within the current screen's working area.
