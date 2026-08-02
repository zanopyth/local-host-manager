# User Guide

## The main window

| Column | Meaning | Shown by default? |
|---|---|---|
| Status | `ON` (green), `OFF` (red, known project not currently running), or `CRASHED` (exited on its own, not stopped by you) | always |
| Port | The TCP port | always |
| Pin | Keeps this row's entry (and Restart button) around after it stops — see **Pin** below | always |
| Custom Name | Editable — see below | on |
| Process | The OS process name holding the port (usually `node`) | on |
| PID | Process ID (blank when OFF) | off |
| CPU | Live CPU usage. Blank until a second sample exists, then a percentage where 100% = one full core busy (not "% of total system capacity") — a single-threaded dev server maxing its one thread reads clearly instead of a barely-visible few percent on a many-core machine | off |
| RAM | Live memory usage snapshot | on |
| Local URL | `http://localhost:<port>` | on |
| Network URL(s) | Every LAN/VPN address others on your network could use to reach it (blank if the server only binds to `127.0.0.1`); see the row Detail popup below to see each one labeled by adapter | off |
| Project Path | The real folder the dev server is running from | off |
| Restart | Restarts the row in place (stop, then start again) | always |
| (button) | **Stop** for running rows, **Start** for known-but-stopped rows | always |

Status/Port/Pin and the two action columns (Restart, Stop/Start) can't be
hidden — they're either the whole point of the table or a click target.
Restart and Stop/Start also stay fixed-width and pinned to the right edge
regardless of window size or column reordering, since they're click
targets, not information to rebalance.

The grid refreshes automatically every 4 seconds. Click **Refresh** to
force it immediately. If you're mid-edit in the Custom Name column, the
auto-refresh politely waits until you're done rather than overwriting your
typing.

## Column chooser, resizing, and reordering

The funnel icon next to **Groups** opens a checklist of the informational
columns (Custom Name, Process, PID, CPU, RAM, Local URL, Network URL(s),
Project Path) — check or uncheck to show/hide them across all three tabs
at once.

Hover the header row to see thin divider lines appear between columns —
drag one to resize, or drag a header to reorder it. Both the widths and
the order you land on are saved and restored on restart, and stay in sync
across Live/History/System (they're really the same table). Restart and
Stop/Start always stay the last two columns no matter how you reorder the
rest.

## Starting, stopping, and restarting a project

- **Stop**: asks for confirmation, then kills the process by PID (and its
  whole child process tree). This kills the actual server process — not
  just "closes a tab" — so treat it like any process-ending action.
- **Start**: only available for rows the app has *previously seen
  running* (so it knows the project's real folder), or that you've
  **Pinned**. For an npm project it runs whichever of `npm start`/
  `npm run dev` actually exists in `package.json`; for anything else it
  replays the exact command line the process was launched with, captured
  the first time it was seen running.
- **Restart**: stops then starts the same row in one click, without a
  separate confirm-then-confirm.

Before any Start/Restart, the port is checked for a collision — if
something's already listening there (a leftover process from a crash, or
something unrelated entirely), you get an upfront choice to kill it and
proceed instead of the launch silently dying a moment later. A launch
that fails within seconds and whose own output mentions an address
conflict (`EADDRINUSE`, "already in use") is logged and notified as a
port conflict rather than a bare "crashed (exit code 1)".

If a port has never been seen running and isn't Pinned, there's no way
for the app to know what to start — it simply won't appear until you run
it manually once.

## Pin

Click the pin icon on any row to keep its entry around (and its Restart
button working) after it stops, instead of it just disappearing once
nothing's listening. Useful for non-Node processes too, which previously
were never remembered once they exited. **Manage Groups…** has a "Pin all
ports in this group" checkbox to bulk-pin an entire group at once.

## Custom Name

Double-click (or select + <kbd>F2</kbd>) any cell in the **Custom Name**
column to rename a row to something meaningful — "Frontend", "Auth API",
etc. Press Enter or click elsewhere to save; clear the text and commit to
remove the name. Names are tied to the project's folder path, so they
survive the project running on a different port later. They also show up
in the tray menu, the group editor, and (if Local Domains is on) as the
basis for that project's `*.localhost` address.

## Auto Crash Restart

Right-click a row with a known project path → **Detail...** to open its
popup, then check **Auto Crash Restart** (at the top of the popup) to
have Localhost Manager relaunch that project on its own the next time it
exits unexpectedly, instead of sitting there marked `CRASHED` until you
notice and click Restart manually. Capped at 5 attempts within a rolling
5-minute window — a genuinely broken project (bad code, a permanently
taken port) gets a handful of real tries and then gives up loudly (a
balloon notification, logged to the Error & Crash Log) instead of
hammering forever. A project you stop yourself is never auto-restarted;
only an unattended exit counts as a crash.

## Log viewer

Double-click any row (Live or History) to open its captured log —
stdout/stderr from the process, without needing a separate visible
console window. Only available for projects the app itself launched
(Start/Restart), since that's the only way it can capture the output.

## Build & Deploy

For a project that needs a build step before it's actually live (a
frontend `dist/` that gets copied into a server's `public/`, for
example): right-click a row → **Detail...**, then:

- **C-Deploy** opens the recipe editor — project folder (where the build
  command runs), the build command itself, the build output folder, and
  any number of target folders to mirror it into. Never runs anything on
  its own.
- **Deploy** actually runs it: the build command, then mirrors the output
  folder into every target (each one exactly, so stale files there get
  deleted too). If no recipe is saved yet, it prompts for one first (same
  dialog as C-Deploy), then runs it immediately after saving.

Running a deploy opens a live shell view showing the build/copy output as
it happens, and stays open afterward as a real interactive shell (type a
follow-up command and press Enter) instead of closing the moment the
scripted part finishes. **Run Again** re-runs the same recipe without
closing the dialog; **Stop Deploy** kills a stuck or too-slow build's
whole process tree without closing the dialog either (a hard kill, not a
literal Ctrl+C — see `KNOWN_ISSUES.md`/`DEVELOPER_GUIDE.md` for why).

A toolbar **Deploy** button next to Groups opens a **Deploy Manager**
listing every tracked port (filterable by group or port range) with the
same Deploy/Configure actions, for running or setting up a deploy without
first finding the row in the grid.

## Dev Servers Only

Checked by default. The scanner sees *every* listening port on your
machine, including background apps (Steam, Discord, browsers, etc.) —
this checkbox filters the list down to things that look like actual
Node/npm dev servers (a `package.json` was found in the recovered working
directory). Uncheck it if you want the unfiltered view.

Note: when **Use Groups** is on *and* you have a group selected, its
selection overrides this toggle entirely (and the root-directory scope,
too) — a project you've manually put in a group stays visible even if it
wouldn't otherwise pass the Dev Servers Only filter.

## Row detail (right-click)

Right-click any row (Live or History) for a **Detail...** menu. It opens a
small, compact popup right at your click point — a "sticky note" summary of
that row, with every column's full value (handy since the grid itself
truncates long paths/URLs) and a small copy-icon button next to each one.
Nothing in the popup is a text field to accidentally click into or edit —
values are display-only except the **Auto Crash Restart** checkbox at the
top; a **Copy All** button at the bottom copies every field at once.

Network URLs get one row each instead of being bunched into a single
comma-separated value, labeled by the actual network adapter they came from
— `Ethernet`, `Wi-Fi`, `Tailscale`, `VMware`, `Hyper-V`, etc. — with the
real/useful ones (Ethernet, Wi-Fi, Tailscale) listed first. Any address
coming from a **virtual, VM-only adapter** (VMware, Hyper-V, VirtualBox,
Docker) has its whole row tinted purple, since that address is only
reachable from virtual machines on this PC, never from another real device
on your network. If Local Domains is running, a **Local Domain** row shows
that project's `*.localhost` address, clickable like Local URL.

## Local Domains

Give each running project a name-based address instead of a raw port —
`http://bodyshop.localhost:2802/` reads better than `http://localhost:5100/`,
and it doesn't change out from under you if the port does. Enable it from
the **Local Domains** menu (off by default), pick a port (default `2802`),
and toggle it on. The address is derived from the row's Custom Name (or
folder name if unset); two projects that'd collide to the same address
automatically get the port appended to stay unique.

It only works from a browser: Chrome, Edge, and Firefox all resolve any
`*.localhost` address to loopback on their own, without needing a DNS entry
or hosts-file edit — but Windows' own DNS resolver doesn't do that, so
non-browser tools (curl, Postman, one service calling another) can't use
these addresses.

Routing by hostname on one shared port needs a wildcard `HttpListener`
binding, which needs a one-time, per-port permission grant (loopback-only —
no firewall change, nothing reachable from another device):

```powershell
netsh http add urlacl url=http://+:2802/ user=Everyone
```

The Local Domains dialog shows this command (with the port you actually
picked) and a Copy button. Run it once as Administrator, then re-enable
(or restart) Local Domains from the dialog. Once it's running, each
project's address shows up in its row's Detail popup as **Local Domain**
— and visiting the bare proxy address with no project name (e.g.
`http://localhost:2802/`) lists every currently-running project's address.

## Web dashboard

Enable it from the **Dashboard** menu (off by default) — pick a port
(default `3199`) and toggle it on. By default it only binds to
`localhost`/`127.0.0.1`, so it's reachable from this PC even without doing
anything else, with click-to-confirm Stop/Start/Restart and per-adapter
clickable LAN/Tailscale links, matching the main window's table.

To reach it from your **phone or another device on the same LAN**, or over
**Tailscale**, run this once as Administrator, then restart the app:

```powershell
netsh http add urlacl url=http://+:3199/ user=Everyone
New-NetFirewallRule -DisplayName "Localhost Manager Dashboard" -Direction Inbound -Protocol TCP -LocalPort 3199 -Action Allow -Profile Domain,Private
```

`-Profile Domain,Private` matters: the dashboard has no login, so anyone who
can reach the port can Stop/Start/Restart your dev servers. Without it, the
rule defaults to *all* profiles including Public — meaning it'd stay
reachable on open/public Wi-Fi too, not just your home LAN or Tailscale.

Without this one-time step, the LAN/Tailscale addresses will show up in the
dashboard's own address list but nothing will actually be listening there —
connections from another device will just time out.

## Themes

**Settings ▸ Preferences ▸ Appearance** offers three themes — **Light**,
**Dark**, and **Terminal** (a Catppuccin-Mocha-inspired palette with flat
corners and a monospace font throughout). Terminal is the default for
fresh installs. Also in Appearance: the style of the divider line between
grouped rows (hairline, dotted, or labeled with the group name).

Changing the theme takes effect after a restart, which the dialog will
offer to do for you.

## Settings ▸ Preferences

**Settings ▸ Preferences...** opens a tabbed dialog:

- **General** — restrict the whole app to only show projects whose
  folder lives under a chosen root directory (e.g.
  `C:\Users\you\Documents\Projects`), handy if this machine also runs
  unrelated npm-based background apps you don't want cluttering the
  view. **Clear (no restriction)** removes the scope. The active scope
  is always shown in the bottom-right corner of the main window.
- **Appearance** — theme and group-divider style, see **Themes** above.
- **Startup** — launch at Windows sign-in, start minimized to tray,
  crash notifications, check for updates on launch.
- **Diagnostics** — the Error & Crash Log viewer, for everything logged
  via `Write-AppErrorLog` (failed launches, taskkill timeouts, unhandled
  UI exceptions, ...).

## Groups

Groups let you bundle related projects (frontend + backend + worker, say)
and control them together.

- **Group** dropdown — pick which group Start All/Stop All act on.
- **Start All** — launches every OFF member of the group, then shows one
  summary ("Started 2 of 3...").
- **Stop All** — shows *one* confirmation listing every process it's
  about to kill, then stops them together (not N separate prompts).
- **Manage Groups…** — create/edit/delete groups. Type a name (or pick an
  existing one from the dropdown to edit it), check off which known
  projects belong to it, optionally check "Pin all ports in this group",
  **Save Group**. A project only shows up in this list once the app has
  seen it running at least once. "Show all listening ports" reveals
  non-Node processes too, so they can be grouped.

Group membership is matched by project folder path, not port — so a
group keeps working even if a member later starts on a different port. If
you rename or move a project's folder, you'll need to re-add it to its
groups (the old path no longer matches).

## Show Groups toggle

This single checkbox controls two things at once:

1. **Toolbar**: unchecking it hides the whole Group/Start All/Stop
   All/Manage Groups row, shrinking the window back to the simple view.
2. **Grid + tray filtering**: unchecking it also narrows what's displayed
   to *only* projects that belong to at least one group — hiding any
   detected npm process that isn't part of a group. This is the
   "decluttered" view: just the things you've deliberately organized,
   nothing else.

Checked = see everything. Unchecked = see only what's grouped. This
applies to the tray's project list and status icon too, not just the main
window.

## System tray

Closing the window (the **X** button) doesn't quit the app — it hides to
the tray, with a one-time notification the first time. The tray icon
itself reflects health: green if everything tracked is running, red if
anything is down (including `CRASHED`).

Right-click the tray icon for:
- **Open Localhost Manager** — restore the window (also works via
  left-click on the icon)
- Every known project, `[ON]`/`[OFF]`/`[CRASHED]`, click to toggle — same
  as the grid
- **Group: <name>** submenus (only when Show Groups is on) with **Start
  All** / **Stop All** — control a whole group without opening the window
- **Refresh**
- **Exit** — the only way to actually quit; everything else just hides

## Data & privacy

Everything the app remembers (history, settings, custom names, groups,
deploy recipes, logs) lives in plain JSON/log files under
`%LOCALAPPDATA%\LocalhostManager\`. Nothing is sent anywhere over the
network except what you explicitly opt into (the web dashboard, Local
Domains — both loopback/LAN-only, never anything external), plus an
optional GitHub check for new releases (Settings ▸ Startup). See
`DEVELOPER_GUIDE.md` for the exact file layout.
