# Known Issues / Limitations

Honest list — nothing here is secret, just worth knowing before you rely
on this for something important.

## By design (not bugs, but easy to misread)

- **Start always runs `npm start`.** There's no way to configure a
  different start command (`yarn dev`, `pnpm run dev`, a custom script,
  etc.) per project. If a project doesn't have an `npm start` script,
  the Start button will open a window and fail.
- **Stop kills the real process**, not "closes a tab." It's
  `Stop-Process -Force` on the actual PID. Treat it like ending a task in
  Task Manager, because that's exactly what it is.
- **A port only becomes "known"** (able to show as `OFF` with a working
  Start button) after the app has seen it running at least once. There's
  no manual "add a project" flow — you start it manually the first time,
  the app picks up its path, and from then on it remembers.
- **Group membership matches by folder path, not name.** Rename or move
  a project's folder and it silently drops out of its groups (the old
  path no longer matches anything). You'll need to re-add it.
- **The Node/npm filter, root-directory scope, and "Show Groups →
  grouped only" filter all stack (AND logic).** It's possible to end up
  with an empty grid because a project meets some but not all active
  filters, without an obvious reason why it's missing. If a project just
  vanishes, check all three settings.

## Real limitations

- **Windows + 64-bit only.** The PEB-reading trick that recovers a
  project's real folder uses hardcoded x64 memory offsets and Win32
  APIs (`ntdll.dll`, `Get-NetTCPConnection`, Windows Forms). It will not
  run on Linux/macOS, and hasn't been tested on 32-bit Windows.
- **No code signing.** The compiled `.exe` isn't signed, so Windows
  SmartScreen shows an "unrecognized publisher" warning on first run.
  This is cosmetic (nothing malicious happens) but it's a legitimate
  trust hurdle for anyone you hand the exe to.
- **PEB reading can fail silently** for processes you don't have access
  to (different user, protected/elevated process, etc.) — the project
  just won't be recognized as a Node project and won't show up under the
  "Node/npm projects only" filter. There's no error surfaced when this
  happens; it just quietly excludes the row.
- **No log capture.** `npm start` output goes to its own separate `cmd`
  window, not into the app. If that window gets closed, you lose the
  scrollback and have no way to tell from the app alone why a server
  crashed (it just flips to `OFF`).
- **No crash vs. intentional-stop distinction.** A project that crashed
  on its own looks identical in the grid to one you stopped on purpose —
  both just show `OFF`.
- **Single-machine, single-user scope.** Everything is stored per-Windows-user
  under `%LOCALAPPDATA%`; there's no way to share a group/custom-name
  setup across machines or accounts except by manually copying the JSON
  files.
- **No automated tests.** Verification has been manual, exercised against
  real running dev servers each time a feature changed. See
  `DEVELOPER_GUIDE.md` for how UI behavior was actually verified
  (direct Win32 calls rather than screenshots, which were unreliable in
  this environment for reasons unrelated to the app itself).
- **Multi-monitor window restore quirks were observed during
  development** on setups with a monitor at negative screen coordinates
  — purely an artifact of automated testing tools (`PrintWindow`), not
  something end users doing normal mouse/keyboard interaction should
  encounter, but noted here in case it resurfaces.
