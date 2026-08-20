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

- [x] **Build the meeting companion as one stateful surface.** Prove detected,
      recording, recovered-end, stopping, short processing and ready states.
      Verify non-activation, full-screen Spaces, multiple displays and
      VoiceOver before replacing native call prompts.
- [x] **Move speaker separation into transcript review.** Recording and initial
      transcription have no meeting profile. Optional review diarises both
      retained source tracks without rerunning speech recognition.
- [x] **Finish stopped recordings as M4A.** Prove packet-preserving
      CAF-to-M4A conversion with Apple media APIs. Publish `Meeting Audio.m4a`
      plus separate source tracks only after duration verification, update
      metadata atomically, and recover unfinished CAF sessions at launch.
- [x] **Add focused voice identification after transcript generation.** Rank
      representative source-audio samples, let a person name a stable voice ID,
      and apply that label across its cluster without becoming a general
      transcript editor.
- [x] **Unify transcript completion and review.** Keep processing visible until
      dismissal or completion, then route both companion and native notification
      actions into one read-only transcript and speaker review window.

## Permissions

- [ ] **Check permission state without prompting, and ask deliberately.** Today
      the microphone and system-audio prompts fire on the first recording, so a
      user's first meeting is the one macOS interrupts, and a denial surfaces
      only as an `OSStatus` in `tapCreationFailed`. Read the current grant state
      with `CGPreflightScreenCaptureAccess()` and
      `AVCaptureDevice.authorizationStatus(for: .audio)`, both of which are
      prompt-free, and show it in Settings. Trigger each grant from an explicit
      Enable control: build a tap, wait for one buffer as proof the grant
      landed, then tear it down. On refusal, deep-link the matching pane
      (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`).
