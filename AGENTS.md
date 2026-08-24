# quill

Quill is Matt's local macOS meeting recorder. `master` is the trunk and upstream
is not in play.

## Read next

1. `README.md` for build, run and distribution commands.
2. `docs/design.md` for implementation architecture and audio flow.
3. `docs/ux.md` for the current product and UI design.
4. `docs/decisions.md` for settled choices and their reasons.
5. `docs/open-questions.md` for possible product paths not yet decided.
6. `TODO.md` for work that remains.

## Constraints and gotchas

- Audio tap and IO closures must remain `@Sendable`. Main-actor isolation on a
  Core Audio callback compiled cleanly and then trapped on the realtime thread.
- Derive live alignment through `SessionTimeline` from the persisted millisecond
  offsets. Direct `Date`-to-sample conversion makes live and recovery disagree.
- Preserve `Sparkle.framework` symlinks and sign its nested helpers inside-out
  before Quill. Flattening or deep-signing it produces an invalid update bundle.
- Optional accepted-frame consumers must run through their own bounded mailbox.
  Synchronous AEC once held the source writer lock until its archive queue could
  drop audio.
- Keep source, mailbox and live-processor drains off the main actor during stop.
  A near-limit backlog otherwise freezes the controls before `Finishing audio`.
- Treat signing as a functional audio change. Hardened runtime without
  `com.apple.security.device.audio-input` produced correctly sized silent files.
- Keep `com.apple.WebKit.GPU` normalized as Safari; the coverage tradeoff is
  settled in `docs/decisions.md`.
- Do not make a recordings-folder check fatal at startup. TCC can allow writes
  while returning an empty directory listing to the menu-bar process.
- Retention cleanup must run only after `transcript.json` exists and after
  `on_stop` terminates. The source audio is otherwise still in use.
- Build and test with `QUILL_HOME` pointing to an isolated directory. The normal
  config file is authoritative user state.
- Keep Quill `.accessory` by default, `.regular` while transcript review is
  visible, and restore `.accessory` when it closes. This is what gives the task
  window Command-Tab presence without a permanent Dock icon.
- Wait for forced process termination before replacing or reopening the app.
  Skipping the post-`pkill` wait produced LaunchServices error `-600` during an
  otherwise valid signed install.
- `docs/design.md` owns implementation and data flow; `docs/ux.md` owns product
  behaviour and UI. Record settled choices in `docs/decisions.md`.
