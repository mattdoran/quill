# Decision log

Dated product and architecture decisions. Newest first.

## 2026-08-10: Keep source audio unless the user chooses deletion

**Decision:** Keep both CAF tracks indefinitely by default. Settings offers
30-day retention and deletion immediately after a successful transcript.

**Why:** A transcript is derived data. The audio is required to verify a quote,
correct recognition errors, or transcribe again with a better engine. Silent
automatic deletion would be an irreversible surprise.

**Consequence:** Only sessions containing `transcript.json` are eligible for
cleanup. Changing to a destructive policy requires confirmation, and cleanup
waits for `on_stop` to finish.

## 2026-08-10: Keep level-based silence detection

**Decision:** Keep the current RMS-based ten-minute nudge. Do not add a
level-variation heuristic or Silero VAD yet.

**Why:** Variation rejects steady fans but still accepts music and keyboards,
while introducing false notifications during quiet speech. Silero makes a more
honest voice claim but adds another model and continuous inference for a
low-cost failure.

**Consequence:** Background noise can suppress the nudge. If real recordings
show that this matters, measure representative noise and speech before changing
the signal.

## 2026-08-10: One macOS application home and one config file

**Decision:** Store all configuration in
`~/Library/Application Support/Quill/config.json`. The menu, Settings and
hand-edited keys share that file.

**Why:** The old config/state precedence silently ignored hand edits and split
one application's persistent state across two files.

**Consequence:** UI writes preserve unknown keys but may normalize JSON layout.
`QUILL_HOME` provides an isolated development and test home.

## 2026-08-10: Enable launch at login only for a fresh install

**Decision:** A first bundled launch registers Quill with `SMAppService`.
Upgrades retain the system's existing choice.

**Why:** A menu-bar recorder that is absent when a meeting starts has already
failed, but an upgrade must not reverse a deliberate opt-out.

**Consequence:** The initialization marker lives in the unified config file.
