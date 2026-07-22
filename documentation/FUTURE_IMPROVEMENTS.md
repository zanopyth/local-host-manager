# Future Improvements

Ideas that came up during development but are out of scope for now,
roughly ordered by how much value they'd add relative to effort.

## High value

- **Auto-restart on crash.** Crash *detection* already exists (a `CRASHED`
  status distinct from `OFF`, driven by the child process's exit vs.
  `StoppedByUser` — see `Start-ProjectAtPath`'s `Exited` handler in
  `LocalhostManager.ps1`); what's still missing is actually doing
  something about it. An opt-in auto-restart (with a capped
  backoff/give-up, same pattern already prototyped in the separate
  Launcher-local exploration's `Invoke-ProjectExitHandler`) would make the
  tray's red-icon alert much more trustworthy to leave running unattended.
- **Per-project custom start command.** Currently everything runs
  `npm start`, hardcoded. Supporting `yarn dev`, `pnpm run dev`, or an
  arbitrary command per project (stored alongside the custom name) would
  remove the biggest "this doesn't work for my setup" friction point.
- **Custom local domains** (Herd/Valet-style, e.g. `myproject.test`
  instead of `localhost:3005`). The pieces already exist in prototype
  form from the Launcher-local exploration (Caddy reverse proxy + local-CA
  HTTPS, trust-once model) and could be ported back in as an opt-in
  per-project toggle — the one feature that would meaningfully
  differentiate this from process managers like PM2 that don't offer it.

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
- **Log viewing in the web dashboard.** The native app already has a
  per-project log viewer (`Show-LogViewer`); the v1.6 web dashboard
  doesn't expose logs at all yet, which is the natural next step now that
  remote viewing/control exists.

## Lower priority / nice-to-have

- **Confirm-before-Start** as an opt-in setting, for anyone who wants
  symmetrical friction with Stop's confirmation.
- **Dark mode** for the grid/dialogs (currently only the tray icons and
  column headers use a dark theme; the rest is default WinForms light).
- **Automated tests.** No test suite currently exists — all verification
  has been manual, driven against real running dev servers. Even a small
  set of tests around the pure-logic half of the script (row building,
  filtering, path normalization) wouldn't require any WinForms/GUI
  scaffolding and would catch regressions early.
