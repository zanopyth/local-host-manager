# Developer Guide

## Stack

Single PowerShell script (`LocalhostManager.ps1`), Windows Forms GUI,
compiled to a standalone `.exe` with [`ps2exe`](https://www.powershellgallery.com/packages/ps2exe).
No external dependencies at runtime — everything is System.Windows.Forms /
System.Drawing / a small chunk of inline C# (`Add-Type`) for Win32 calls
the .NET Process class doesn't expose.

There is no build system beyond the single `Invoke-PS2EXE` call in
`INSTALLATION.md` — the `.ps1` *is* the source of truth, and the `.exe` is
a disposable artifact regenerated from it and attached to each GitHub
Release (never committed to the repo).

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
| `history.json` | Every project ever seen running: `{ port: { ProjectPath, ProcessName, Pinned, AutoRestart, CommandLine } }` | port |
| `settings.json` | Theme, column visibility/order/fill-weights, `OnlyNode`, `RootDir`, `ShowGroups`, dashboard/proxy config, startup options, etc. | — |
| `customnames.json` | User-assigned display names | normalized project path (falls back to `port:<n>` if path unknown) |
| `groups.json` | `{ groupName: [projectPath, ...] }` | group name |
| `deploydefs.json` | Build & Deploy recipes: `{ WorkingDir, BuildCommand, SourceDir, TargetDirs }` | normalized project path |
| `logs\app-error.log` | Every logged warning/error (`Write-AppErrorLog`), capped at a fixed line count | — |
| `logs\<sanitized-project-path>.log` | Captured stdout/stderr for a project this app itself launched | normalized project path, sanitized to a filename |

All are plain JSON (except the `.log` files), safe to hand-edit while the
app is closed. `history.json`/custom names/groups/deploy defs are read
into memory once at launch, kept in `$script:*` variables, mutated in
place, and re-saved on change.

## High-level architecture

The script has two halves:

1. **Pure logic** (top of file, before the `GUI` comment banner) — no
   Windows Forms objects touched. Scanning, persistence, filtering. Easy
   to reason about / unit-test in isolation from a console if needed.
2. **GUI** (everything after) — builds the WinForms tree, wires events,
   and calls into the logic half.

### The scanning pipeline

```
[background runspace, own loop] netstat-equivalent scan -> per-port process
  info -> Get-ProcessWorkingDirectory (PEB read) -> written into
  $script:LiveCache every ~4s

Get-LiveListeners            reads the current $script:LiveCache snapshot
                              (no scanning on this thread)
  -> Build-Rows                  merges live + remembered (history) ports,
                                  applies OnlyNode/RootDir filters, attaches
                                  CustomName/Pinned/AutoRestart/Cpu/Mem
    -> Get-DisplayRowsSplit      splits into Live (ON) / History (OFF,
                                  CRASHED) / System (OS-owned, opt-in),
                                  and on every cycle also feeds
                                  Publish-DashboardRows and
                                  Update-ProxyRouteMap so the web
                                  dashboard and Local Domains stay current
      -> Render-Grid              repopulates each DataGridView
      -> Update-TrayIcon          recomputes tray icon/tooltip
      -> Build-TrayMenuItems      rebuilds the tray context menu (lazily,
                                  only right before it opens)
```

`Build-Rows` is called with different `OnlyNode`/`RootDir` arguments
depending on the caller: the main grid respects the user's current
checkbox/scope settings, while the tray and the group editor always call
it with no restriction, because those need the *complete* picture of
every known npm project regardless of what the main window happens to be
filtered to.

Alongside the scanning pipeline, three more background runspaces can be
running depending on what's enabled: the **web dashboard** listener
(`Start-WebDashboard`), the **Local Domains reverse proxy** listener
(`Start-ProxyServer`), and per-invocation **Build & Deploy** shells
(`Show-DeployRunDialog`, one `cmd.exe /k` per open deploy dialog). All
follow the same shape as the background poller: their own runspace, a
`[hashtable]::Synchronized` cache as the only thing shared back to the UI
thread, and a UI-thread `Timer` that drains queued actions/results rather
than the background thread ever touching a WinForms control directly.

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
detection, unless it's Pinned or falls back to a previously-known
path/command line (see the "unreadable restart" fix in `CHANGELOG.md`
1.8.1, and the optional `SeDebugPrivilege` self-elevation at startup that
can let the read succeed against sandboxed processes when this app itself
is run as Administrator).

### DataGridView gotchas (learned the hard way)

A few non-obvious fixes are baked into the grid setup and worth knowing
about before touching that code:

- **`DoubleBuffered` is protected** on `DataGridView` — enabled via
  reflection (`GetProperty(..., NonPublic)`). Without it, the
  clear-and-rebuild refresh cycle visibly flickers.
- **`AutoSizeColumnsMode = 'Fill'` is load-bearing, not a style choice.**
  An earlier attempt (v1.14.0) switched to fixed pixel widths so every
  column could be manually resized — but once the columns' total width
  could exceed the table's actual width, that produced an untheme-able
  native white horizontal scrollbar *and* misaligned the hand-drawn
  group-divider line against the now-scrolled row bounds. Fill mode was
  never actually the resize-blocker (dragging a column border under Fill
  just redistributes `FillWeight` among the others, which already works);
  the real fix (v1.14.1) was reverting to Fill and persisting widths as
  fill-weight ratios instead of literal pixels.
- **Setting a grid property synchronously inside certain grid events
  throws a reentrancy exception**, and this has bitten this codebase
  twice with two different messages:
  - Setting `.FillWeight` inside `ColumnWidthChanged` during a live
    window-border resize throws *"This operation cannot be performed
    while an auto-filled column is being resized"* — a resize
    recalculates every Fill column's width, firing the same event a real
    column drag would, but WinForms refuses the write mid-resize. Fixed
    with a 400ms debounce timer (`Schedule-ColumnLayoutSave`): the event
    handler just notes what changed and (re)arms the timer; the actual
    `.FillWeight` write happens on the timer tick, safely after whatever
    triggered the event has settled.
  - Setting `.CurrentCell`, or calling `Rows.Clear()`/rebuilding the grid,
    synchronously from inside `CellEnter` or `CellContentClick` while
    that same click is still being dispatched throws *"Operation is not
    valid because it results in a reentrant call to
    SetCurrentCellAddressCore"* or *"Operation cannot be performed in
    this event handler"* respectively. Both showed up from perfectly
    reasonable-looking code: a `CellEnter` handler redirecting focus off
    a separator row by setting `.CurrentCell`, and `Invoke-TogglePin`
    refreshing the grid right after a click with no confirm dialog or
    other yield point in between (contrast with `Invoke-ToggleAction`/
    `Invoke-Restart`, which show a `MessageBox` first — that nested
    modal loop happens to pump enough messages for the grid's internal
    click-dispatch state to settle before they call `Refresh-Grid`).
    Fixed both the same way: defer the mutation via
    `$control.BeginInvoke([Action]{ ... }.GetNewClosure())` so it runs
    after the current click has fully unwound instead of nested inside
    it. **The general rule**: never mutate a DataGridView's rows,
    columns, or current cell synchronously from inside one of its own
    cell/row events unless something upstream in the same call (a
    `MessageBox.Show`, a `DoEvents` loop) is known to have already let
    the grid's internal dispatch settle first. When in doubt, defer via
    `BeginInvoke`.
- **A wrapped `Label`'s `.Height` is stale until it's been through a real
  layout pass.** `AutoSize = $true` with a `MaximumSize` (word-wrap) does
  not recompute `.Height` on a freshly-constructed, not-yet-parented
  label — reading it immediately after creation always returns the
  single-line default, even if the text visibly wraps once shown. This
  silently broke the Configure Deploy dialog's row layout (a value box
  overlapping its label's wrapped second line). Fixed by measuring with
  `TextRenderer.MeasureText($text, $font, $maxSize,
  [TextFormatFlags]::WordBreak).Height` instead of trusting `.Height` —
  the same technique already used elsewhere to size the Restart column
  against the Terminal theme's wider monospace font.
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

### Background polling

`Get-NetTCPConnection` and `Get-NetIPAddress` are WMI-backed and routinely
take 200ms-1s+ to return. Earlier versions called them directly from the
UI-thread refresh timer, which froze the whole window (most visibly, drag
via the title bar would stutter every ~4 seconds — the timer tick blocked
the same thread that pumps mouse-move messages).

As of v1.5.2 the scan runs on its own background runspace instead:

```
$script:LiveCache          [hashtable]::Synchronized — the only thing
                            shared between the UI runspace and the poller
$script:BackgroundPollScript   scriptblock run in the background runspace:
                            loops forever, does the actual
                            Get-NetTCPConnection / Get-NetIPAddress /
                            Get-ProcessWorkingDirectory / CPU+RAM sampling
                            work, and swaps a freshly-built hashtable into
                            $Cache.Listeners / $Cache.LanIps each cycle
                            (whole-object reference swap, never mutates
                            a dict the UI thread might be mid-iteration on)
$script:PollRunspace /
$script:PollShell          created once near startup via
                            [runspacefactory]::CreateRunspace() +
                            [powershell]::Create(), invoked with
                            .BeginInvoke() (non-blocking)
Stop-BackgroundPoller       sets $Cache.StopRequested, stops/disposes the
                            shell, closes the runspace — called from
                            FormClosing on real exit
```

The background scriptblock re-declares helper functions like
`Get-ProcessWorkingDirectory` rather than reusing the ones defined in the
main runspace's script scope — runspaces don't share function/variable
scope, only the process's AppDomain, so P/Invoke types loaded once via
`Add-Type` at the top of the file are visible from it, but functions and
`$script:` variables are not. The same constraint applies to the web
dashboard and proxy runspaces below.

At startup, `Application.Run` is preceded by a short bounded wait (up to
3s) for `$script:LiveCache.Ready` so the first paint isn't an empty grid
that immediately repopulates.

### Web dashboard and Local Domains proxy

Both are opt-in `HttpListener`-based servers, each on its own background
runspace, following the same synchronized-cache shape as the poller
above — see `Start-WebDashboard`/`$script:DashboardListenScript` and
`Start-ProxyServer`/`$script:ProxyListenScript`. Neither blocks the UI
thread; a `Timer` on the UI side drains queued actions (dashboard
Stop/Start/Restart clicks) and results back out.

The proxy needs a wildcard bind (`http://+:<port>/`) to route by
`Host` header to whichever real port a project is on — a listener bound
to literal `http://localhost:<port>/` only ever matches requests whose
Host header is literally `localhost`, never `<name>.localhost`. Wildcard
binds need a one-time `netsh http add urlacl` grant per port (shown, with
a Copy button, in the Local Domains dialog) — loopback-only, no firewall
change. The dashboard, by contrast, can fall back to binding just
`localhost` for local-only use; it only needs the same `netsh` grant (plus
a firewall rule) if you want to reach it from another device.

A single relay request handler
(`$script:ProxyHandleRequestScript`) runs against a small `RunspacePool`
rather than a synchronous accept-process-accept loop — a real page load
fires several requests in parallel (document + JS + CSS + favicon + ...),
and HTTP.SYS's own backlog queue was rejecting the 3rd/4th concurrent
asset with a bare 503 while request #1 was still being relayed, back when
this was single-threaded.

### Refresh loop and edit-safety

A `System.Windows.Forms.Timer` on a 4-second interval drives a periodic
refresh, which reads the current `$script:LiveCache` snapshot
(effectively instant) instead of scanning. It bails out early if any
grid's `.IsCurrentCellInEditMode` is true, so it never clobbers an
in-progress Custom Name edit — see the DataGridView gotchas section above
for why that guard alone isn't sufficient for every grid-mutating call
site, only for the ones checking it right before mutating.

### Tray / close-to-tray

`FormClosing` is intercepted: unless `$script:ReallyExit` was explicitly
set (only done by the tray's **Exit** item), the close is cancelled and
the form is hidden instead, with a one-time balloon tip. The tray icon's
color and tooltip are recomputed on every refresh.

### Single-instance guard

A named, process-independent `System.Threading.Mutex` is created at
startup (`LocalhostManager_SingleInstance_Mutex`). If it already exists,
this is a second launch — show a message and exit for real (not just
unwind the script; a duplicate instance previously left an invisible,
windowless copy running in the background if it only called `exit`).

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
   happy — bump `$script:AppVersion` in the script and the `-version`
   argument together.
4. Commit the `.ps1`/`.ico` changes, push, and cut a new GitHub Release
   with the freshly built `.exe` attached (the `.exe` itself is
   gitignored, never committed to the repo).

There's no automated test suite. Verification so far has been manual:
launching the compiled exe, exercising each feature against real running
npm dev servers, checking `logs\app-error.log` for anything new, and
using direct Win32 API calls (`SendMessage`/`BM_CLICK`, `IsWindowVisible`,
`MoveWindow` to script a live window resize, etc.) to exercise UI
interaction and assert on real control state rather than screenshots,
where screenshots proved unreliable in this environment.
