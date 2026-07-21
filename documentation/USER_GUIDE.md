# User Guide

## The main window

| Column | Meaning |
|---|---|
| Status | `ON` (green) if the port is currently listening, `OFF` (red) if it's a known project that isn't running right now |
| Port | The TCP port |
| Custom Name | Editable — see below |
| Process | The OS process name holding the port (usually `node`) |
| PID | Process ID (blank when OFF) |
| Local URL | `http://localhost:<port>` |
| Network URL(s) | Every LAN/VPN address others on your network could use to reach it (blank if the server only binds to `127.0.0.1`); see the row Detail popup below to see each one labeled by adapter |
| Project Path | The real folder the dev server is running from |
| (button) | **Stop** for running rows, **Start** for known-but-stopped rows |

The grid refreshes automatically every 4 seconds. Click **Refresh** to
force it immediately. If you're mid-edit in the Custom Name column, the
auto-refresh politely waits until you're done rather than overwriting your
typing.

## Starting and stopping a project

- **Stop**: asks for confirmation, then kills the process by PID. This
  kills the actual server process — not just "closes a tab" — so treat it
  like any process-ending action.
- **Start**: only available for rows the app has *previously seen running*
  (so it knows the project's real folder). It opens a new visible `cmd`
  window and runs `npm start` there. That window is where you'll see the
  dev server's console output; closing it does **not** stop the server —
  use Stop for that.

If a port has never been seen running, there's no way for the app to know
what to start — it simply won't appear until you run it manually once.

## Custom Name

Double-click (or select + <kbd>F2</kbd>) any cell in the **Custom Name**
column to rename a row to something meaningful — "Frontend", "Auth API",
etc. Press Enter or click elsewhere to save; clear the text and commit to
remove the name. Names are tied to the project's folder path, so they
survive the project running on a different port later. They also show up
in the tray menu and the group editor in place of the raw folder name.

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
values are display-only; the icon button is the only clickable thing per
row, plus a **Copy All** button at the bottom that copies every field at
once.

Network URLs get one row each instead of being bunched into a single
comma-separated value, labeled by the actual network adapter they came from
— `Ethernet`, `Wi-Fi`, `Tailscale`, `VMware`, `Hyper-V`, etc. — with the
real/useful ones (Ethernet, Wi-Fi, Tailscale) listed first. Any address
coming from a **virtual, VM-only adapter** (VMware, Hyper-V, VirtualBox,
Docker) has its whole row tinted purple, since that address is only
reachable from virtual machines on this PC, never from another real device
on your network.

## Settings — root directory scope

**Settings…** opens a dialog with one option: restrict the whole app to
only show projects whose folder lives under a chosen root directory (e.g.
`C:\Users\you\Documents\Projects`). Handy if this machine also runs
unrelated npm-based background apps you don't want cluttering the view.
**Clear (no restriction)** removes the scope. The active scope is always
shown next to the Settings button.

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
  projects belong to it, **Save Group**. A project only shows up in this
  list once the app has seen it running at least once.

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
anything is down.

Right-click the tray icon for:
- **Open Localhost Manager** — restore the window (also works via
  left-click on the icon)
- Every known project, `[ON]`/`[OFF]`, click to toggle — same as the grid
- **Group: <name>** submenus (only when Show Groups is on) with **Start
  All** / **Stop All** — control a whole group without opening the window
- **Refresh**
- **Exit** — the only way to actually quit; everything else just hides

## Data & privacy

Everything the app remembers (history, settings, custom names, groups)
lives in plain JSON files under `%LOCALAPPDATA%\LocalhostManager\`. Nothing
is sent anywhere over the network. See `DEVELOPER_GUIDE.md` for the exact
file layout.
