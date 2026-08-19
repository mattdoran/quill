# Open questions

Possible product paths that need investigation or a design decision. Nothing in
this file is committed roadmap or current behaviour.

## Meeting-aware start and stop

Should Quill offer to start recording when a meeting begins and stop when it
ends, while leaving the decision to record with the person?

Granola provides a useful reference model:

- Calendar events supply the expected meeting identity and an opportunity to
  prompt at the start.
- Call detection can prompt for ad-hoc meetings, but the person still chooses
  whether to start.
- In observed use, ending a call finishes the recording immediately. The signal
  Granola uses to recognise that event is not yet known.
- Silence can remain a fallback when there is no clean call-end signal.

Questions:

- Is calendar access worth the permission and product scope it introduces?
- What macOS event lets Granola react immediately when a call hangs up?
- Can Quill observe that event without administrator privileges or fragile
  process inspection?
- What false-positive rate does call detection produce in normal use?
- Should the existing ten-minute silence nudge remain as the final fallback?

Next evidence needed: identify public macOS signals for native and browser call
starts and stops, then measure their false-positive rate in normal use. Audio
activity alone cannot distinguish a meeting from unrelated playback.

## Per-recording meeting profile

The current two `Separate Voices` controls persist globally and are read when
transcription runs. A later change can therefore affect a recording already in
the queue.

Should each recording instead snapshot a processing profile in `meta.json`?
One prompt framed around the physical meeting could derive both track settings:

| Choice | Microphone track | System track |
|---|---|---|
| People on the call | one local speaker | separate remote speakers |
| People in the room | separate local speakers | no remote speakers expected |
| People in both | separate local speakers | separate remote speakers |

The labels need testing. `On the call`, `In the room`, and `Both` may be clearer
than meeting-type labels such as remote and hybrid. Asking how many people are
at both ends may cost more comprehension than the avoided diarisation work is
worth.

Questions:

- Does the start confirmation carry this choice, or does a call-detected prompt
  carry it before recording begins?
- Should Quill remember the last choice, infer a default from the initiating
  app or calendar event, or always require a choice?
- For `People on the call`, is always diarising the system track the simplest
  honest behaviour?
- Should an in-room profile omit system capture, or retain it because a meeting
  can change shape after recording starts?

## Live recording indicator

Should Quill add a Granola-style draggable indicator while another app is in
front? Its purpose would be immediate confidence and access, not a second
workflow surface.

The smallest useful surface may contain elapsed time and a stop control. This
would require revisiting the current decision that Quill has no recording
windows while retaining the menu-bar item as canonical status.

Questions:

- Is it always visible while recording, or optional after first use?
- Can it remain unobtrusive across full-screen apps and multiple displays?
