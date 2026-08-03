# Future Improvements

Ideas that came up during development but are out of scope for now,
roughly ordered by how much value they'd add relative to effort. Most of
what used to be on this list has since shipped — see `CHANGELOG.md` for
the full history (auto-restart on crash, custom local domains, dark mode,
launch-at-startup, export/import settings, per-project command replay for
non-npm processes, and more all landed between v1.7.0 and v1.17.4).

## Medium value

- **Column sorting** by clicking headers (currently fixed sort by port).
  Columns are freely resizable/reorderable/hideable now, but not
  sortable.
- **Search/filter box** in the grid, for machines with many tracked
  projects where scrolling gets old. Distinct from the existing
  column-visibility chooser (the funnel icon next to Groups) — that
  toggles which columns show, not which rows.
- **Log viewing in the web dashboard.** The native app has a per-project
  log viewer (double-click a row → `Show-LogViewer`, capturing stdout/
  stderr for managed processes); the web dashboard's `/api/*` routes
  still only cover rows/meta/stop/start/restart, not logs.
- **An explicit per-project custom start command**, typed and saved
  rather than inferred. `Get-NpmRunScript` already picks between `start`/
  `dev` from `package.json`, and non-npm processes replay their
  previously-captured command line — but there's still no UI to type an
  arbitrary override (e.g. force `pnpm run dev` on a project that also
  has an `npm start` script you don't want used).

## Lower priority / nice-to-have

- **Confirm-before-Start** as an opt-in setting, for anyone who wants
  symmetrical friction with Stop's confirmation.
- **Code signing.** Would remove the SmartScreen warning on first run —
  meaningful if this is ever shared beyond one person's machine.
- **Expand automated test coverage.** `tests\PureLogic.Tests.ps1` covers
  the pure-logic pieces with no WinForms/network/process dependency
  (path normalization, filtering, the network-adapter classifier, the
  live/history merge step) — see `DEVELOPER_GUIDE.md`. The GUI half still
  has no automated coverage; verification there remains manual.
