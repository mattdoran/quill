# quill

Quill is Matt's local macOS meeting recorder. `master` is the trunk and upstream
is not in play.

## Read next

1. `README.md` for build, run and distribution commands.
2. `docs/ux.md` for the current product and UI design.
3. `docs/decisions.md` for settled choices and their reasons.
4. `TODO.md` for work that remains.

## Constraints and gotchas

- Audio tap and IO closures must remain `@Sendable`. Main-actor isolation on a
  Core Audio callback compiled cleanly and then trapped on the realtime thread.
- Treat signing as a functional audio change. Hardened runtime without
  `com.apple.security.device.audio-input` produced correctly sized silent files.
- Do not make a recordings-folder check fatal at startup. TCC can allow writes
  while returning an empty directory listing to the menu-bar process.
- Retention cleanup must run only after `transcript.json` exists and after
  `on_stop` terminates. The source audio is otherwise still in use.
- Build and test with `QUILL_HOME` pointing to an isolated directory. The normal
  config file is authoritative user state.
- `docs/ux.md` is the design authority. Record new settled choices in
  `docs/decisions.md`, not in this file.
