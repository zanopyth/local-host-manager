# Future Improvements

Ideas that came up during development but are out of scope for now,
roughly ordered by how much value they'd add relative to effort.

## High value

- **Inline log capture.** Pipe each project's stdout/stderr into the app
  (a per-row "View Log" panel) instead of a separate `cmd` window. Would
  also enable...
- **Crash detection.** Right now a crashed process and an intentionally
  stopped one look identical (`OFF`). Capturing the child process's exit
  and distinguishing "stopped by user" from "exited unexpectedly" would
  make the tray's red-icon alert much more trustworthy to leave running
  unattended. Natural follow-on: optional auto-restart on crash.
- **Per-project custom start command.** Currently everything runs
  `npm start`, hardcoded. Supporting `yarn dev`, `pnpm run dev`, or an
  arbitrary command per project (stored alongside the custom name) would
  remove the biggest "this doesn't work for my setup" friction point.

## Medium value

- **Launch on Windows startup.** A checkbox that registers the exe to
  run at login (Startup folder shortcut or a registry Run key), so the
  tray icon is just always there.
- **Code signing.** Would remove the SmartScreen warning on first run —
  meaningful if this is ever shared beyond one person's machine.
- **Export/import settings & groups.** A "backup my setup" /
  "restore on a new machine" flow — currently the only way is manually
  copying the JSON files under `%LOCALAPPDATA%\LocalhostManager\`.
- **Search/filter box** in the grid, for machines with many tracked
  projects where scrolling gets old.
- **Column sorting** by clicking headers (currently fixed sort by port).

## Lower priority / nice-to-have

- **Multiple LAN/VPN network labels** — currently all non-loopback IPs
  are listed together; labeling which is "LAN" vs "Tailscale" vs "VMware"
  would reduce ambiguity in the Network URL(s) column.
- **Confirm-before-Start** as an opt-in setting, for anyone who wants
  symmetrical friction with Stop's confirmation.
- **Dark mode** for the grid/dialogs (currently only the tray icons and
  column headers use a dark theme; the rest is default WinForms light).
- **Automated tests.** No test suite currently exists — all verification
  has been manual, driven against real running dev servers. Even a small
  set of tests around the pure-logic half of the script (row building,
  filtering, path normalization) wouldn't require any WinForms/GUI
  scaffolding and would catch regressions early.
