# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [1.16.0] - 2026-07-29

### Added
- The rule between grouped rows is now a subtle muted hairline by
  default instead of a bold accent-colored bar, which read more like a
  warning stripe than a section break. Two alternative styles - dotted,
  and labeled (names the group starting below it) - are available in
  Settings → Appearance.
- A small busy indicator in the toolbar (below the column-chooser
  button) blinks red/green for the duration of any Start/Stop/Restart
  action, using the same ring-and-dot look as the dashboard status
  pill.

### Fixed
- Restarting, stopping, or starting a project could make the whole
  window appear "Not Responding" for several seconds - every step
  (confirm dialogs, killing the old process, waiting for the port to
  free up, starting the new one) ran fully blocking on the UI thread.
  These now keep pumping the window's message loop while they wait,
  and a re-entrancy guard ignores a second click while one is already
  in flight.
- Launching the app while it was already running correctly showed
  "Localhost Manager is already running" - but the duplicate process
  never actually exited afterward, leaving an invisible, windowless
  copy running in the background with no taskbar entry and no tray
  icon. Enough repeated duplicate launches could make the real
  instance seem to have vanished entirely. `exit` only unwound the
  script; the duplicate's process now hard-exits for real.
- Start All/Stop All, and every other owner-drawn button, rendered
  their icon+text a couple of pixels off-center - the text was
  measured with one text-rendering engine (GDI) and painted with
  another (GDI+), which don't agree on metrics.
- Two Settings dialog labels cleaned up: the crash-notification
  toggle's label wrapped and clipped mid-word, and the root-directory
  label was tightened up.

## [1.15.2] - 2026-07-28

### Added
- The table's scrollbars now render in Windows' native dark mode
  (Dark/Terminal themes only) instead of the plain white/light native
  bar - most visible on the horizontal one, which previously stood out
  starkly regardless of the app's theme. Not a pixel-exact Catppuccin
  Mocha match (there's no managed API to recolor a native ScrollBar
  control to arbitrary colors - Windows renders its own fixed dark
  gray for this), but real dark-mode rendering rather than jarring
  white. Re-applied on resize and after the table's rows change, since
  the scrollbar's underlying window isn't created until one is
  actually needed for the first time.

## [1.15.1] - 2026-07-28

### Added
- Column resize handles in the table header are now visible - as thin
  divider lines between header cells - while hovering the header bar,
  making it obvious where to grab to resize a column. Hidden the rest
  of the time to keep the normal borderless look; hand-drawn rather
  than a native border style, which has a documented history of
  rendering glitches under this app's theme (see the CellBorderStyle
  comment in New-PortsGrid).

### Fixed
- The Restart column clipped to "Res..." under the Terminal theme's
  wider monospace font - its width was a pixel guess tuned for Light/
  Dark's Segoe UI. Now measured against the theme's actual font
  (TextRenderer.MeasureText, matching how the cell text is actually
  rendered) instead of a hardcoded number, so it fits in any theme.
- Restart's text color was the muted/secondary TextDim - now Success
  green, matching "ON" status and the Start All button, since it's a
  live clickable action, not secondary information.

## [1.15.0] - 2026-07-28

### Changed
- The Restart and Stop/Start columns are now fixed-width and
  un-resizable, and always stay the last two (right-most) columns in
  the table regardless of window size or drag-to-reorder - they're
  click targets, not information to rebalance, so they no longer grow,
  shrink, or drift the way the informational columns are meant to.
  Since WinForms has no per-column "don't let this be reordered" flag,
  this is enforced by normalizing the saved column order (Log/Action
  forced to the end) every time a reorder is persisted or restored,
  rather than by blocking the drag gesture itself.

## [1.14.3] - 2026-07-28

### Fixed
- "Exception setting 'FillWeight': This operation cannot be performed
  while an auto-filled column is being resized." when dragging the app
  window's own border. Resizing the window recalculates every Fill-mode
  column's pixel width against the new available space, firing
  ColumnWidthChanged the same as an actual column drag - but the
  column-layout code was reacting to that event by immediately writing
  to .FillWeight to persist/sync it, which WinForms refuses while it's
  still mid-resize itself. Save/sync is now debounced: a resize or
  reorder just notes which grid changed and (re)starts a short 400ms
  timer, and the actual write happens on that timer's tick, safely
  after whatever triggered the event (a column drag, a window resize)
  has fully settled. Verified against both a normal resize drag and an
  aggressive rapid-fire resize burst.

## [1.14.2] - 2026-07-28

### Fixed
- Startup crash dialog introduced by 1.14.1 itself: "Exception setting
  'DisplayIndex': ... 'Save-ColumnLayout' is not recognized...". Setting
  a column's DisplayIndex during the startup call to Update-ColumnLayout
  fires ColumnDisplayIndexChanged synchronously - unlike a button click,
  that startup call runs as part of the script's own top-to-bottom
  setup, not deferred until everything has finished loading, so it hit
  the handler (which calls Save-ColumnLayout) before the script had even
  reached that function's own definition further down. Moved the
  startup call to after both column-layout functions are defined.
- The fix above uncovered a second, subtler issue with the same root
  cause: the compiled app could take a very long time to finish
  starting (Dashboard/Local Domains never came up, no error shown).
  Adding the Fill-mode grids to their parent tab pages for the first
  time triggers WinForms' first real layout pass, which fires
  ColumnWidthChanged for every column - each firing was calling
  Save-ColumnLayout (a settings.json write) followed by a full
  Update-ColumnLayout pass across all three grids, which could itself
  trigger more firings, cascading into dozens of redundant writes
  during ordinary startup. The guard that's supposed to suppress
  exactly this (SyncingColumnLayout) was only held during the explicit
  Update-ColumnLayout calls, not the whole startup sequence, so this
  particular firing (from adding the grids to their parent) fell
  outside it. Now held from before the very first grid is created
  until immediately before the message loop starts - genuine user
  drags can't happen before then anyway, so this costs nothing.

## [1.14.1] - 2026-07-28

### Fixed
- v1.14.0's switch to fixed-width columns (meant to make Status
  resizable again) let the columns' total width exceed the table's
  actual width once the window got narrower than that total. That
  caused two new problems: a horizontal scrollbar WinForms can't theme
  (always renders white/native regardless of the app's theme), and the
  hand-drawn group-divider line landing against row bounds that no
  longer matched the visible/scrolled area, especially while resizing
  the window. Reverted to the table's Fill layout (which already
  supports drag-to-resize - dragging a column border redistributes fill
  weight among the others, and was never actually the problem;
  Status's old content-based auto-size was), which guarantees columns
  always exactly fill the table's width, so neither bug can occur.
  Column widths are now persisted as fill-weight ratios rather than
  literal pixels; reordering is unaffected.

## [1.14.0] - 2026-07-28

### Added
- **Drag to resize and reorder every column**, in all three tables. The
  table switched from an auto-fit ("Fill") layout to fixed, explicit
  starting widths so every column is freely resizable - Fill mode (and
  the per-column AllCells override the Status column briefly had in
  v1.13.0) computes width automatically, which silently disables manual
  dragging entirely. Both the width and the left-to-right order you end
  up with are saved and restored on restart, and stay in sync across
  Live/History/System since they're really the same table.

### Fixed
- Status column resizing, regressed in v1.13.0 by the fix for its
  width (AllCells auto-sizing, like Fill, doesn't allow manual drag).
  Superseded by the fixed-width approach above.

## [1.13.0] - 2026-07-28

### Added
- **Column chooser**: a new toolbar icon (filter glyph, next to Groups)
  opens a checklist to show/hide the informational columns (Custom Name,
  Process, PID, CPU, RAM, Local URL, Network URL(s), Project Path) across
  all three tables at once. Status/Port/Pin/Log/Action stay put - they're
  either the whole point of the table or a click target, not just info to
  declutter. CPU is off by default (usually 0% until something's actually
  busy); RAM stays on (varies row to row even at idle). Persisted, and
  forward-compatible with future toggleable columns via per-key defaults.

### Changed
- Status column now sizes to its own content ("ON"/"OFF"/"CRASHED")
  instead of stretching proportionally with the table's Fill layout,
  which left a lot of dead padding around a 2-7 character word. Freed
  width goes to the columns that actually need it.

## [1.12.1] - 2026-07-28

### Fixed
- CPU/RAM columns never actually updated after their first paint. The
  grid only repaints when a row-data "signature" changes (to avoid
  flickering every refresh tick), and that signature didn't include
  Cpu/Mem - so a row's other fields staying the same (the normal,
  steady-state case) meant the grid kept showing whatever it painted on
  the very first tick, which is always blank (no CPU sample exists yet
  that early). Added Cpu/Mem to the signature.

## [1.12.0] - 2026-07-28

### Added
- **CPU and RAM columns** in the Live/History/System tables, and in each
  row's Detail popup. RAM is a live snapshot; CPU is a percentage sampled
  across poll ticks (blank, not "0%", until a second sample exists - those
  mean different things). 100% means one full core busy (matches the
  older Task Manager / Process Explorer / htop convention, not modern Task
  Manager's default "% of total system capacity") - on a many-core
  machine, normalizing by core count would make a single-threaded dev
  server maxing out its one thread read as a barely-visible few percent,
  which defeats the point of the column. Also exposed via the web
  dashboard's `/api/rows` JSON.

## [1.11.0] - 2026-07-28

### Added
- **Local Domains**: an opt-in reverse proxy (new "Local Domains" menu, off
  by default) that gives every running project a friendly address -
  `http://bodyshop.localhost:2802/` instead of `http://localhost:5100/` -
  routed by hostname to whichever port that project actually happens to be
  on. Works in Chrome/Edge/Firefox, which resolve `*.localhost` to loopback
  on their own; doesn't work from curl/Postman/other non-browser tools,
  since Windows' own DNS resolver doesn't do that resolution. Requires a
  one-time `netsh http add urlacl` grant per port (shown, with a Copy
  button, right in the Local Domains dialog) - loopback-only, no firewall
  change. The friendly address also shows up in each running project's
  Detail popup ("Local Domain", clickable) once it's live.
- Visiting the bare proxy address (no project name) shows a small index
  page listing every currently-running project's `*.localhost` address.

## [1.10.0] - 2026-07-27

### Added
- **Port collision protection**: Start, Restart, and Start All now check the
  target port right before launching. If it's already held - by an
  untracked leftover of the same project (e.g. after a crash/restart of
  Localhost Manager itself) or by something unrelated - you get an
  upfront choice to kill it and proceed, instead of the launch silently
  dying a moment later.
- **Smarter crash diagnostics**: a launch that exits within seconds of
  starting, whose own output mentions an address conflict (`EADDRINUSE`,
  "already in use", ...), is now logged and notified as a port conflict
  instead of a bare, unhelpful "crashed (exit code 1)".

### Fixed
- Settings > Appearance: picking a **Group Divider** style silently
  unchecked whichever **Theme** option was selected, and vice versa - both
  radio-button groups shared the same parent control, so WinForms treated
  all six as one mutually exclusive set (and Save, reading an
  all-unchecked Theme group, quietly fell back to Light). Each group now
  lives in its own container.

### Changed
- Default theme (for fresh installs, and upgrades from before the Theme
  setting existed) is now **Terminal** instead of Light.

## [1.9.0] - 2026-07-27

### Added
- **Terminal theme**: a third Settings > Appearance option alongside Light
  and Dark - a Catppuccin Mocha-inspired palette (near-black panels, one
  blue accent, semantic green/red status colors), flat/square corners
  instead of rounded, and a monospace font (Cascadia Mono) throughout, for
  a terminal-UI look. Applies after a restart, same as switching Light/Dark.

### Fixed
- Toolbar buttons ("Refresh", "Groups", "Start All", "Stop All") clipped
  their own text under the wider monospace font - widened to fit.
- Dashboard dialog: the intro/hint text wrapped and got vertically clipped
  under the monospace font, and the port field's border/background stayed
  native white instead of following the theme. Dialog resized and
  relayouted, port field themed.
- Manage Groups dialog: the group-name field and project checklist stayed
  native white regardless of the active theme.
- Group-divider rows in the ports table were an easy-to-miss blank gap
  (and could pick up a stray focus-rectangle outline); now a deliberate
  accent-colored divider line, and no longer selectable via keyboard/mouse
  navigation.

## [1.8.10] - 2026-07-26

### Fixed
- **Settings menu**: "Dev Servers Only" and "Use Groups" rendered with
  their checkmark glyph overlapping the first letter or two of their own
  text ("Dev Ser...", "se Groups"). Root cause was in the stock
  `ToolStripProfessionalRenderer` itself, not this app's own rendering -
  reproduced identically with a bare, unthemed, undecorated `MenuStrip`.
  Padding.Left on these two items now clears the checkbox glyph.

## [1.8.9] - 2026-07-26

### Fixed
- **Groups popup**: the checked-list dropdown was a fixed 130px tall no
  matter how many groups existed, leaving a large empty band below the
  last item (and before the rounded border) for anyone with only 1-3
  groups defined. Now sizes to fit the actual items, still capped at
  130px so a long group list keeps scrolling instead of growing unbounded.
- **File / Help menus and the tray menu** reserved the standard ~25px
  left-side gutter every `ToolStripDropDownMenu` sets aside for
  checkmark/icon glyphs, even though none of their items use one - a
  permanent, unused-looking gap down the left edge of every plain-text
  menu. Turned off for these (Settings keeps it: "Dev Servers Only" /
  "Use Groups" are real checkable items that render into that gutter).
- Help menu's dropdown text color was never set (File and Settings were),
  so it silently fell back to black regardless of the active theme.

## [1.8.8] - 2026-07-26

### Fixed
- **Check for Updates** threw "Exception setting 'ForeColor': Cannot convert
  null to type 'System.Drawing.Color'" and got stuck on "Checking for
  updates" once the result landed. Cause: the dialog's timers read
  `$script:Theme.<Color>` (a dotted member-access off a script-scope
  variable) from inside a `.GetNewClosure()`'d tick handler, which
  PowerShell intermittently resolves to `$null` instead of the real color.
  Now reads the needed theme colors into local variables before the
  closure is created.
- Row detail popup's per-row copy icon (the small button next to each
  value, e.g. Local URL, Network URL, Project Path) rendered as a blank
  square instead of the copy glyph. Cause: its `.Text` was set *after*
  `Initialize-ModernButton`, which owner-draws from a snapshot of `.Text`
  taken at init time - so the glyph assignment never took effect visually.
  Now set before init.

### Added
- Row detail popup: **Local URL** is now a clickable link that opens it in
  the default browser.

## [1.8.7] - 2026-07-26

### Fixed
- Menu bar (and other) text looked smeared/rainbow-fringed - "unfinished",
  as if ClearType hadn't settled. Root cause: the app never declared DPI
  awareness, so on any scaled display (125%/150%, the common laptop/4K
  default) Windows silently bitmap-stretched the whole rendered window to
  match, which is what fringed the text (confirmed by zooming into a
  screenshot: the OS-drawn title bar text, never stretched, stayed crisp
  at the same zoom level the app's own text visibly fringed at). Now
  declares Per-Monitor-v2 DPI awareness at startup (falling back through
  the older per-process APIs on pre-1703 Windows), before any window is
  created. Note: since the app's layout uses fixed pixel positions with no
  DPI-scaling logic of its own, it will now render at its literal declared
  size - sharp, but physically smaller on a scaled display than the
  blurry upscale it was showing before

### Changed
- **Check for Updates** (Help menu) now opens immediately with an animated
  "Checking..." state instead of giving no feedback until a MessageBox
  showed up seconds later (or never, if it silently failed) - resolves in
  place into up-to-date / update-available / check-failed once the
  background check lands

## [1.8.6] - 2026-07-26

### Added
- **Check for Updates** (Help menu): compares the running version against
  GitHub's latest release tag on startup (Settings ▸ Startup, on by
  default) and on demand. A found update shows a tray balloon (click to
  open the download page) and a link in the About dialog; the on-demand
  check also confirms when you're already up to date. The network call
  runs on a background runspace so a slow/offline check never blocks the UI
- **Backup Settings... / Restore Backup...** (File menu): zips
  settings/groups/history/custom-names into a single `.lhmbackup` file and
  can restore one back, for moving to a new machine or recovering after a
  reinstall. Restoring confirms first and restarts the app to reload

## [1.8.5] - 2026-07-26

### Fixed
- The 1.8.4 About-icon fix (switching `.ToBitmap()` for `Graphics.DrawIcon`)
  turned out not to fix it - both go through `System.Drawing.Icon`, whose
  own pixel data is corrupted for every frame in this file (confirmed: the
  two produced identical static). The embedded PNG frames themselves decode
  perfectly on their own. Now reads the `.ico`'s frame directory directly
  and decodes the chosen frame's PNG bytes straight into a Bitmap, never
  touching `System.Drawing.Icon`

## [1.8.4] - 2026-07-26

### Fixed
- About dialog's app icon rendered as colored static instead of the actual
  logo - `Icon.ToBitmap()` corrupts modern `.ico` files whose larger frames
  are embedded as PNG (GDI+'s bitmap-conversion path can't decode those).
  Now drawn via `Graphics.DrawIcon`, the same Windows-native path already
  used everywhere else the icon is shown (title bar, tray)

## [1.8.3] - 2026-07-26

### Changed
- **Start All** now gets the same inline split-pill confirm as Stop All (X
  to cancel, check to confirm) instead of firing immediately on click -
  green instead of red, since it's not destructive, but a misclick still
  launches every stopped project in the group

## [1.8.2] - 2026-07-26

### Changed
- **Stop All**'s inline confirm step is now a real split pill instead of a
  single button that just relabels itself "Confirm?" - the first click
  divides it into two independently-clickable halves: a plain X (cancel,
  left) and a solid check (confirm, right), so backing out is an explicit
  option next to the destructive one instead of only a 3-second timeout or
  clicking away

## [1.8.1] - 2026-07-26

### Fixed
- A live, listening port could lose its project identity entirely if
  something else restarted it in a way this app couldn't read the new
  process's memory (its working-directory PEB read) - notably a dev server
  restarted from inside another tool's sandboxed/job-restricted shell (an
  agent or CI runner), which blocks that kind of cross-process read from
  unrelated apps even though the process itself is completely normal and
  visible. Previously this clobbered the port's ProjectPath to null on the
  very next refresh, silently dropping it out of Groups, Manage Groups, and
  the Dev Servers Only filter - even if it had been pinned. Build-Rows now
  falls back to the port's last known-good path/command line when a live
  read comes back empty, so a previously-identified port keeps its
  group/pin association through an unreadable restart. A process that
  resolves its own path always takes priority over the fallback
- Also now enables SeDebugPrivilege on its own process token at startup
  when available (present only on an elevated/Administrator launch - a
  silent no-op otherwise). Where present, this can let the PEB read
  succeed against sandboxed processes directly, instead of relying on the
  history fallback above

## [1.8.0] - 2026-07-25

### Added
- **Dark theme** (Settings ▸ Preferences ▸ Appearance): a full dark palette
  across the main window, grid, dialogs, tray menu, and popups. Takes
  effect after a restart, which the Settings dialog will offer to do for
  you as soon as you change it
- **Preferences redesign**: the Settings dialog is now tabbed (General /
  Appearance / Startup / Diagnostics) instead of one long stacked list
- **Launch at Windows startup** (Settings ▸ Startup)
- **Start minimized to tray** (Settings ▸ Startup) - skips showing the
  main window on launch, straight to the tray icon
- **Crash notifications toggle** (Settings ▸ Startup) - the balloon tip
  shown when a tracked dev server crashes unexpectedly can now be turned
  off; the error log still records it either way

### Changed
- Toolbar's "Groups: N selected" button now just reads "Groups" (matching
  the size/shape of Refresh/Start All/Stop All); the selection detail
  moved to a hover tooltip

### Fixed
- Right-clicking the tray icon could occasionally render the popup menu
  partly behind the taskbar - the menu's on-screen position was being
  computed from its previous (often shorter) size before its items were
  rebuilt for the current project list

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
