# Open questions

Possible product paths that need investigation or a design decision. Nothing in
this file is committed roadmap or current behaviour.

## Start and stop around the meeting

Could Quill offer to record when a meeting starts, and stop when it ends,
without recording automatically?

Granola provides a useful reference model:

- Calendar events supply the expected meeting identity and an opportunity to
  prompt at the start.
- Call detection can prompt for ad-hoc meetings, but the person still chooses
  whether to start.
- In observed use, ending a call finishes the recording immediately. The signal
  Granola uses to recognise that event is not yet known.
- Silence can remain a fallback when there is no clean call-end signal.

Quill should investigate which public macOS signals reveal that a call app has
started or stopped using the microphone, including whether the responsible app
can be identified reliably for native apps and browser calls. Audio activity
alone is not enough to distinguish a meeting from unrelated playback.

Questions:

- Is calendar access worth the permission and product scope it introduces?
- What macOS event lets Granola react immediately when a call hangs up?
- Can Quill observe that event without administrator privileges or fragile
  process inspection?
- What false-positive rate does call detection produce in normal use?
- Should the existing ten-minute silence nudge remain as the final fallback?

## Per-recording meeting profile

The current two `Separate Voices` controls expose track-processing choices and
persist globally. They are read when transcription runs, so a later change can
also affect a recording already waiting in the queue.

A recording should instead snapshot its chosen processing profile in
`meta.json`. The prompt should ask one question in terms of the physical
meeting, then derive the track settings:

| Choice | Microphone track | System track |
|---|---|---|
| People on the call | one local speaker | separate remote speakers |
| People in the room | separate local speakers | no remote speakers expected |
| People in both | separate local speakers | separate remote speakers |

The labels need testing. `On the call`, `In the room`, and `Both` may be clearer
than naming meeting types such as remote and hybrid. The prompt should not ask
how many people are at both ends unless that distinction changes a useful
outcome. A single remote speaker does not need diarisation, but asking for that
detail may cost more comprehension than the avoided processing is worth.

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

Consider a Granola-style draggable indicator visible while another app is in
front. Its purpose is immediate confidence and access, not a second recording
window.

The smallest useful surface may contain elapsed time, live capture activity and
a stop control. Clicking it could reveal the live transcript or return to a
larger meeting surface if one exists. This would require revisiting the current
decision that Quill has no recording windows, while retaining the menu-bar item
as the canonical status.

Questions:

- Does the indicator show one combined activity signal or separate microphone
  and system signals?
- Is it always visible while recording, or optional after first use?
- Can it remain unobtrusive across full-screen apps and multiple displays?

## Live transcript and questions during a meeting

Live transcription is useful in its own right, not only as a capture-health
indicator. It allows someone to verify recent words, recover something they
missed, search the conversation, and ask questions against what has happened so
far.

Quill's current pipeline is offline: completed tracks are echo-cleaned,
transcribed separately, optionally diarised, and merged. A live path would be
provisional and separate from the canonical final transcript. The final pass
should still run from the completed recordings so it can use offline echo
cancellation and diarisation.

A bounded experiment could transcribe rolling chunks, retain a recent live
window, and answer questions only from that provisional text. It should measure
latency, model and battery cost, correction churn, and how understandable the
two tracks are before offline cleanup.

Questions:

- Does the installed Parakeet/FluidAudio version support a genuine streaming
  decoder, or would Quill need chunked file transcription or another engine?
- How much transcript history should be held during the meeting?
- Can local question answering be useful enough without introducing a cloud
  service or a second large model?
- What UI contains the transcript and question input without turning Quill into
  a full meeting workspace?
