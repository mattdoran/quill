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

- [ ] **Ask for permissions deliberately, not on first record.** Today the
      microphone and system-audio prompts fire during the first recording, and a
      denial surfaces only as an `OSStatus` in `tapCreationFailed`. Both grants
      should be requested from an explicit Enable control in Settings, and a
      refusal should deep-link to its own pane:
      `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`
      for the tap and `?Privacy_Microphone` for the microphone.
      `Privacy_AudioCapture` is the anchor that matches `kTCCServiceAudioCapture`
      and lands on the "System Audio Recording Only" list, which is where Quill
      is granted. `Privacy_ScreenCapture` is a different anchor for a permission
      Quill does not use.

      The microphone side is easy: `AVCaptureDevice.authorizationStatus(for:
      .audio)` reads the state without prompting.

      The tap side has no public equivalent. It is gated by
      `kTCCServiceAudioCapture`, confirmed in the TCC database, and no framework
      exposes a prompt-free check for it. Granola reads it through the private
      `TCCAccessPreflight` in TCC.framework. The alternative is to build a tap
      and wait for one buffer, which is the request itself, so checking and
      asking collapse into the same action. Decide which before building the
      Settings UI, since a status display needs the check to be separable.
