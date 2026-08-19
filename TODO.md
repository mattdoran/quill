# TODO

Work that remains. Product and architecture decisions live in
`docs/decisions.md`; the UI specification lives in `docs/ux.md`.

## Verification

- [ ] **Review the installed menu and Settings window visually.** Both build and
      launch, but the status item is not exposed to the available UI automation.
- [ ] **Measure mute and device switching in a real browser meeting.** Safari
      and Chrome Meet detection passed on 2026-08-19; dismissing Chrome's start
      prompt correctly produced neither recording nor an end prompt.

## Transcription

- [ ] **Add WhisperKit large-v3-turbo as a fallback and re-transcription
      option.** Parakeet remains the fast English default. Re-transcription is
      one reason source audio is retained by default.

## Controls

- [ ] **Add a real global recording hotkey.** Menu key equivalents fire only
      while the menu is open and must not be presented as global controls.

## End-to-end meeting workflow

- [ ] **Build the meeting companion as one stateful surface.** Prove detected,
      recording, recovered-end, stopping, short processing and ready states.
      Verify non-activation, full-screen Spaces, multiple displays, VoiceOver
      and the ten-second handoff before replacing native call prompts.
- [x] **Snapshot optional voice separation per recording.** Use `Off`, `On the
      call`, `In the room` and `Both`; selection never
      blocks recording, both tracks are always captured, and queued processing
      reads the profile from `meta.json`.
- [ ] **Finish stopped recordings as M4A.** First prove packet-preserving
      CAF-to-M4A conversion with Apple media APIs. Publish `Meeting Audio.m4a`
      plus separate source tracks only after duration verification, update
      metadata atomically, and recover unfinished CAF sessions at launch.
- [ ] **Add focused voice identification after transcript generation.** Rank
      representative source-audio samples, let a person name a stable voice ID,
      and apply that label across its cluster without becoming a general
      transcript editor.
