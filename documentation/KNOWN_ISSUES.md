# Known Issues / Limitations

Honest list — nothing here is secret, just worth knowing before you rely
on this for something important.

## By design (not bugs, but easy to misread)

- **Start still runs `npm start`/`npm run dev` for npm projects** —
  `Get-NpmRunScript` picks whichever of `start`/`dev` actually exists in
  `package.json`, so it's no longer a hardcoded guess, but there's still no
  UI to type an arbitrary custom command for an npm project. Non-npm
  processes (a plain Python server, a `.bat`-launched static server, ...)
  work differently: the background poller captures the exact command line
  a process was actually launched with and replays that on Start/Restart —
  but only once the app has seen it running at least one time. A port with
  neither a `package.json` nor a previously-captured command line shows
  "No Known Start Command" instead of failing silently.
- **Stop kills the real process**, not "closes a tab." It's a
  `taskkill /T /F` on the actual PID (and its whole child tree). Treat it
  like ending a task in Task Manager, because that's exactly what it is.
- **A port only becomes "known"** (able to show as `OFF` with a working
  Start button) after the app has seen it running at least once. There's
  no manual "add a project" flow — you start it manually the first time,
  the app picks up its path, and from then on it remembers. **Pin** keeps
  a port's entry around after it stops (instead of it disappearing from
  History), but doesn't shortcut this first-seen requirement.
- **Group membership, Custom Name, and Build & Deploy recipes all match
  by folder path, not name.** Rename or move a project's folder and it
  silently drops out of its groups, loses its custom name, and loses its
  saved deploy recipe (the old path no longer matches anything for any of
  the three). You'll need to redo all of them.
- **The Node/npm filter, root-directory scope, and "Show Groups →
  grouped only" filter all stack (AND logic).** It's possible to end up
  with an empty grid because a project meets some but not all active
  filters, without an obvious reason why it's missing. If a project just
  vanishes, check all three settings.
- **Local Domains is browser-only.** Chrome/Edge/Firefox resolve
  `*.localhost` to loopback themselves; Windows' own DNS resolver doesn't,
  so curl, Postman, and one service calling another over that address
  won't work. It also needs a one-time `netsh http add urlacl` grant per
  port before it can bind — see `USER_GUIDE.md`.
- **The web dashboard has no login/authentication.** Anyone who can reach
  the port (which, once the one-time `netsh`/firewall step is done, means
  anyone on your LAN or Tailscale) can Stop/Start/Restart every tracked
  project from a browser with no confirmation beyond a click. Keep it off
  Public network profiles — the documented firewall rule in
  `USER_GUIDE.md` deliberately scopes to `Domain,Private` for this reason.
- **Auto Crash Restart is capped at 5 attempts in a rolling 5-minute
  window**, then gives up loudly (a balloon notification, logged to
  `app-error.log`) rather than retrying forever. A project stuck in an
  immediate crash loop won't be relaunched indefinitely.

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
  "Node/npm projects only" filter unless it's Pinned. Running the app
  elevated (Administrator) enables `SeDebugPrivilege`, which can let the
  PEB read succeed against some processes that would otherwise fail (e.g.
  ones started from inside another tool's sandboxed shell); a build-tool
  path or history fallback covers most of what's left. There's no error
  surfaced when a read fails — it just quietly falls back or excludes the
  row.
- **Single-machine, single-user scope.** Everything is stored per-Windows-user
  under `%LOCALAPPDATA%`; there's no built-in sync across machines or
  accounts — **Backup Settings.../Restore Backup...** (File menu) covers
  moving to a new machine manually, but there's no live/automatic sharing.
- **No automated tests.** Verification has been manual, exercised against
  real running dev servers each time a feature changed. See
  `DEVELOPER_GUIDE.md` for how UI behavior was actually verified
  (direct Win32 calls and programmatic window manipulation rather than
  screenshots, which were unreliable in this environment for reasons
  unrelated to the app itself).
- **Multi-monitor window restore quirks were observed during
  development** on setups with a monitor at negative screen coordinates
  — purely an artifact of automated testing tools (`PrintWindow`), not
  something end users doing normal mouse/keyboard interaction should
  encounter, but noted here in case it resurfaces.
