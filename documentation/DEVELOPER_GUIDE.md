# Developer Guide

## Stack

Single PowerShell script (`LocalhostManager.ps1`), Windows Forms GUI,
compiled to a standalone `.exe` with [`ps2exe`](https://www.powershellgallery.com/packages/ps2exe).
No external dependencies at runtime — everything is System.Windows.Forms /
System.Drawing / a small chunk of inline C# (`Add-Type`) for one Win32
call the .NET Process class doesn't expose.

There is no build system beyond the single `Invoke-PS2EXE` call in
`INSTALLATION.md` — the `.ps1` *is* the source of truth, and the `.exe` is
a disposable artifact regenerated from it.

## File layout

```
LocalhostManager.ps1        - the entire app
LocalhostManager.ico        - window/tray icon (healthy state, green)
LocalhostManager-alert.ico  - tray icon (alert state, red)
LocalhostManager.exe        - compiled output (gitignored, shipped via Releases)
```

## Runtime data (not in the repo)

Everything persisted lives under `%LOCALAPPDATA%\LocalhostManager\`:

| File | Contents | Keyed by |
|---|---|---|
| `history.json` | Every npm project ever seen running: `{ port: { ProjectPath, ProcessName } }` | port |
| `settings.json` | `OnlyNode`, `RootDir`, `ShowGroups` | — |
| `customnames.json` | User-assigned display names | normalized project path (falls back to `port:<n>` if path unknown) |
| `groups.json` | `{ groupName: [projectPath, ...] }` | group name |

All four are plain JSON, safe to hand-edit while the app is closed (or
even while running — most are only re-read at startup, though
`history.json`/custom names/groups are re-read into memory once at launch
and then kept in `$script:*` variables, mutated in place, and re-saved on
change — see below).

## High-level architecture

The script has two halves:

1. **Pure logic** (top of file, before the `GUI` comment banner) — no
   Windows Forms objects touched. Scanning, persistence, filtering. Easy
   to reason about / unit-test in isolation from a console if needed.
2. **GUI** (everything after) — builds the WinForms tree, wires events,
   and calls into the logic half.

### The scanning pipeline

```
Get-LiveListeners            netstat-equivalent scan → per-port process info
  → Get-ProcessWorkingDirectory   PEB read to find the real project folder
  → Build-Rows                   merges live + remembered (history) ports,
                                  applies OnlyNode/RootDir filters,
                                  attaches CustomName
    → Limit-ToGroupedRows        optional final filter: only grouped paths
      → Refresh-Grid             repopulates the DataGridView
      → Update-TrayIcon          recomputes tray icon/tooltip
      → Build-TrayMenuItems      rebuilds the tray context menu (lazily, only
                                  right before it opens — see Known Issues history)
```

`Build-Rows` is called with different `OnlyNode`/`RootDir` arguments
depending on the caller: the main grid respects the user's current
checkbox/scope settings, while the tray and the group editor always call
it with `-OnlyNode $true -RootDir ''` (no restriction) because those need
the *complete* picture of every known npm project regardless of what the
main window happens to be filtered to.

### Why a custom PEB reader exists

`npm start` shows up in Windows process listings (WMI, `Get-CimInstance
Win32_Process`, etc.) as just `node ...\npm-cli.js start` — the actual
project folder is nowhere in the command line, because `npm` is installed
once globally and the project path only ever exists as the process's
*current working directory*, which .NET doesn't expose for other
processes.

`Get-ProcessWorkingDirectory` gets it anyway by reading the target
process's PEB (`ProcessEnvironmentBlock`) directly out of its memory:

1. `NtQueryInformationProcess` → `PROCESS_BASIC_INFORMATION.PebBaseAddress`
2. Read `PEB + 0x20` → pointer to `RTL_USER_PROCESS_PARAMETERS`
3. Read `params + 0x38` → the `CurrentDirectory` `UNICODE_STRING` (length
   + buffer pointer)
4. Read that buffer → the actual folder, e.g.
   `C:\Users\you\Projects\my-app`

Offsets are x64-specific (`0x20`/`0x38`); this assumes both the target
process and this app are running as 64-bit, which is the default on any
current Windows install. Wrapped in `try/catch` — if it fails for any
reason (protected process, access denied, 32-bit mismatch), the row just
has no `ProjectPath` and is excluded from the "is this an npm project"
detection.

### DataGridView flicker + column layout gotchas (learned the hard way)

A few non-obvious fixes are baked into the grid setup and worth knowing
about before touching that code:

- **`DoubleBuffered` is protected** on `DataGridView` — enabled via
  reflection (`GetProperty(..., NonPublic)`). Without it, the
  clear-and-rebuild-every-4-seconds refresh cycle visibly flickers.
- **`Dock='Fill'` on the grid conflicted with a sibling `Dock='Top'`
  panel** in this environment — column headers would silently collapse to
  0px height and the first row would render on top of them. Fixed by
  *not* using `Dock` for the grid at all: it's manually positioned via
  `Anchor = 'Top,Bottom,Left,Right'` plus an explicit `Location`/`Size`
  that's recalculated by hand (`Update-GroupsVisibility`) whenever the
  toolbar height changes (i.e. when the group row shows/hides).
- **`Columns.AddRange(@(...))` throws** ("no columns... columns must be
  added first") when passed an untyped PowerShell array — .NET can't
  implicitly convert `Object[]` to `DataGridViewColumn[]`. Every
  `AddRange` call in this file explicitly casts:
  `[System.Windows.Forms.DataGridViewColumn[]]$cols = @(...)`.
- **`ColumnHeadersHeight` is ignored** unless
  `ColumnHeadersHeightSizeMode = 'DisableResizing'` is also set first.
- The tray's `ContextMenuStrip` is rebuilt lazily on its `Opening` event,
  not on every timer tick — rebuilding it while it's already open (from a
  background timer) made it visibly blink.

### Refresh loop and edit-safety

A `System.Windows.Forms.Timer` on a 4-second interval drives
`Refresh-Grid`. It bails out early if `$grid.IsCurrentCellInEditMode` is
true, so it never clobbers an in-progress Custom Name edit.

### Tray / close-to-tray

`FormClosing` is intercepted: unless `$script:ReallyExit` was explicitly
set (only done by the tray's **Exit** item), the close is cancelled and
the form is hidden instead, with a one-time balloon tip. The tray icon's
color and tooltip are recomputed on every refresh via `Update-TrayIcon`.

### Icon loading

Both `.ico` files are loaded once at startup via `Get-AppIcon`, which
looks for them next to the running exe/script (`$script:AppDir`, resolved
from `$PSCommandPath` when running as a raw `.ps1`, or the exe's own
`MainModule.FileName` directory when compiled — `ps2exe` doesn't set
`$PSCommandPath` inside the compiled runtime). Falls back to extracting
the exe's own embedded icon, then to `SystemIcons.Application`, so a
missing `.ico` file never crashes the app — it just looks generic.

## Making changes

1. Edit `LocalhostManager.ps1` directly.
2. Test by running it as a script first (faster iteration than
   recompiling): `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
   LocalhostManager.ps1`
3. Recompile with `Invoke-PS2EXE` (see `INSTALLATION.md`) once you're
   happy — bump the `-version` argument.
4. Commit the `.ps1`/`.ico` changes, push, and cut a new GitHub Release
   with the freshly built `.exe` attached (the `.exe` itself is
   gitignored, never committed to the repo).

There's no automated test suite. Verification so far has been manual:
launching the compiled exe, exercising each feature against real running
npm dev servers, and using direct Win32 API calls
(`SendMessage`/`BM_CLICK`, `IsWindowVisible`, etc.) to script UI
interaction and assert on real control state rather than screenshots,
where screenshots proved unreliable in this environment.
