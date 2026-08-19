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
