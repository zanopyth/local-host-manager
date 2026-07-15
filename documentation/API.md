# Internal Function Reference

This app has no external/network API — it's a single-process desktop
tool. This document is the reference for its internal PowerShell
function "API": every function defined in `LocalhostManager.ps1`, what it
takes, what it returns, and what it touches.

## Process / filesystem inspection

### `Get-ProcessWorkingDirectory -ProcId <int>`
Returns the real working directory of an arbitrary running process by
reading its PEB, or `$null` if the read fails for any reason. See
`DEVELOPER_GUIDE.md` for how. Uses the inline C# type
`LocalhostManager.ProcCwd` (defined at the top of the file) for the
`NtQueryInformationProcess`/`ReadProcessMemory` P/Invoke calls.

### `Get-LiveListeners`
No parameters. Scans every TCP port currently in the `Listen` state
(`Get-NetTCPConnection`), resolves each to a process name + working
directory, and filters out well-known Windows system processes
(`$script:ExcludedProcessNames`). Returns a hashtable keyed by port
(string) → `@{ Port; ProcId; ProcessName; LocalAddr; ProjectPath; IsNode }`.
`IsNode` is `$true` when `package.json` exists in the recovered
`ProjectPath`.

### `Get-LanIPv4Addresses`
No parameters. Returns every non-loopback, non-APIPA IPv4 address bound
to this machine (LAN, VPN/Tailscale, virtual adapters — anything) as a
string array. Used to build the "Network URL(s)" column.

## Row building / filtering

### `Build-Rows -OnlyNode <bool> -RootDir <string>`
The core "what should be displayed" function. Merges `Get-LiveListeners`
output with `Load-History`, so ports that aren't currently running but
were previously seen (and are npm projects) still show up as `OFF` rows
with a known restart path. Applies the `OnlyNode` and `RootDir` (via
`Test-PathUnderRoot`) filters, attaches each row's `CustomName` via
`Get-CustomNameKey`, and persists any newly-seen npm project back to
`history.json`. Returns an array of `[PSCustomObject]` with:
`Status, Port, CustomName, ProcessName, ProcId, LocalUrl, LanUrls,
ProjectPath, Action`, sorted by port number.

Called with different arguments by different parts of the UI — see
`DEVELOPER_GUIDE.md` → "The scanning pipeline".

### `Test-PathUnderRoot -Path <string> -Root <string>`
Case-insensitive path-prefix test used by the root-directory scope
feature. Returns `$true` if `Root` is empty (no restriction configured).

### `Limit-ToGroupedRows -Rows <array>`
Post-filter applied on top of `Build-Rows` output. If
`$script:Settings.ShowGroups` is `$true`, returns `Rows` unchanged.
Otherwise narrows it to only rows whose `ProjectPath` appears in any
group (via `Get-AllGroupedPaths`).

### `Get-AllGroupedPaths`
No parameters. Returns a `HashSet[string]` of every normalized project
path across all groups (union, not per-group).

### `Get-CustomNameKey -ProjectPath <string> -Port <string>`
The lookup key used for the custom-names dictionary: the normalized
project path if known, otherwise `"port:<port>"` as a fallback so a
custom name can still be set on a port whose path couldn't be resolved.

### `Get-NormalizedPath -Path <string>`
Lowercases and trims a trailing backslash — the canonical form used
everywhere paths are compared (custom names, group membership).

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

`Load-Settings` additionally applies defaults (`OnlyNode = $true`,
`RootDir = ''`, `ShowGroups = $true`) and back-fills `ShowGroups` for
settings files written before that feature existed.

## Actions (start/stop)

### `Start-ProjectAtPath -ProjectPath <string>`
Runs `npm start` for the given folder in a new visible `cmd.exe` window
(`/k`, so the window stays open showing output). Returns `$true`/`$false`
for success. This is the *only* start mechanism — there is no per-project
custom start command (see `FUTURE_IMPROVEMENTS.md`).

### `Stop-ProjectById -ProcId <int>`
`Stop-Process -Force` on the given PID. Returns `$true`/`$false`.

### `Invoke-ToggleAction -data <row object>`
The single-row toggle used by the grid's Action button and every
per-project tray menu item. Shows a confirm dialog before stopping (not
before starting). Calls `Refresh-Grid` afterward.

### `Start-GroupAll -Name <string>` / `Stop-GroupAll -Name <string>`
Bulk equivalents used by the toolbar's Start All/Stop All buttons *and*
the tray's per-group submenu items. `Stop-GroupAll` shows exactly one
confirmation listing every process about to be stopped, rather than one
prompt per process. Both call `Refresh-Grid` and show a single summary
`MessageBox` at the end.

## GUI wiring (not really an "API", but referenced elsewhere in these docs)

- `Refresh-Grid` — rebuilds the DataGridView from `Build-Rows` +
  `Limit-ToGroupedRows`; no-ops while a cell is being edited.
- `Update-GroupsVisibility` — shows/hides the group toolbar row and
  resizes the grid to fill the freed/reclaimed space.
- `Update-ScopeLabel` / `Update-GroupCombo` — small UI-sync helpers.
- `Update-TrayIcon` — recomputes the tray icon color/tooltip.
- `Build-TrayMenuItems` — rebuilds the tray context menu; wired to the
  menu's `Opening` event, not the refresh timer.
- `Get-KnownProjects` — every distinct project the app has ever seen,
  for populating the Manage Groups checklist.
- `Show-SettingsDialog` / `Show-ManageGroupsDialog` — modal dialogs.
