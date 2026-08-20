# Open questions

Possible product paths that need investigation or a design decision. Nothing in
this file is committed roadmap or current behaviour.

## Call lifecycle reliability

Quill offers to start recording when a recognized meeting begins and offers to
stop when its input ends. Both actions remain explicit. The open decision is
whether per-application evidence can ever justify automatic stopping or a
stronger signal such as calendar proximity.

### Call lifecycle signal, 2026-08-19

Core Audio exposes the required process state through public API. Read
`kAudioHardwarePropertyProcessObjectList`, then each process object's PID,
bundle ID, input devices and `kAudioProcessPropertyIsRunningInput`. This reports
which processes are actively using an input stream without administrator access
or process command-line inspection.

One observed Continuity Phone call ran through `com.apple.avconferenced`, not a
Phone process. Quill therefore needs explicit aliases for known helper bundle
IDs, including `com.apple.avconferenced -> com.apple.FaceTime`. No Phone or
FaceTime lifecycle API is needed.

Detection should be limited to a fixed registry of meeting application families
such as FaceTime, Chrome, Firefox, Safari, Zoom, Teams, Slack, Webex, WhatsApp,
Arc, Brave, Discord, Dialpad and Gather. Unknown microphone users must not
trigger a meeting prompt.

#### Start detection pseudocode

The detector polls and checks elapsed time on each poll. It does not schedule
work or wait inside the update function:

```text
confirmed_apps = uninitialized
pending_starts = map from app to first-seen time
pending_ends = map from app to first-missing time

every 1 second, with one poll immediately at startup:
    processes = get_active_input_processes()
    observed_apps = normalize_and_filter(processes)
    started, ended = update(observed_apps, current_time)
    handle_started(started)
    handle_ended(ended)

update(observed_apps, now):
    if confirmed_apps is uninitialized:
        confirmed_apps = observed_apps
        return empty, empty  # Baseline only; do not claim a start at launch.

    discard pending starts for apps no longer observed
    discard pending ends for apps observed again

    for each observed app not in confirmed_apps:
        record now in pending_starts if it has no timestamp

    for each confirmed app not in observed_apps:
        record now in pending_ends if it has no timestamp

    started = pending starts at least 2 seconds old
    ended = pending ends at least 2 seconds old
    add started to confirmed_apps and remove ended from confirmed_apps
    clear the completed timestamps
    return started, ended
```

#### End detection pseudocode

The same Core Audio transition supplies the primary end signal. A conservative
first version asks before stopping because a meeting application can release
its microphone when muted, during a device change or during browser navigation.

```text
handle_started(apps):
    if not recording and no call prompt is pending:
        show "Meeting detected" with a tokenized "Record" action

on start action(prompt_token):
    if the token is still current and that app is still confirmed:
        start capture with a new recording token bound to that app

handle_ended(apps):
    if an ended app owns the current bound recording:
        show "Meeting ended?" with its recording token and a "Stop" action

on stop action(recording_token):
    if the token still identifies the current recording:
        stop that recording
```

Calendar proximity and an explicit browser-extension `meeting-ended` event can
later strengthen this signal. Quill has no live transcript or cloud processing,
so transcript classification is not part of the design.

### Current Quill implementation

The menu app polls the public Core Audio process state once per second and is
the only owner of product behavior. A pure reducer confirms start and end only
after two stable seconds. Initial state establishes a baseline without a start
event, and applications are tracked independently when their activity overlaps.

Recognized applications can produce a `Meeting detected` notification with an
explicit `Record` action. Accepting it binds that recording to the application
family. Two seconds of absence from that application produces a `Meeting
ended?` notification with an explicit `Stop` action.
Manual recordings remain unbound. Unknown processes are diagnostic evidence
only and cannot prompt.

The menu app appends changed raw snapshots to the disposable
`cache/call-detection.log`. `quill watch-calls` runs the same scanner and reducer
as an observation-only test harness; it prints diagnostics and owns no product
notifications or recording actions.

Reducer tests cover initial snapshots, stable start and end, transient input and
overlapping recognized applications. Remaining coverage belongs around helper
PID replacement, loopback exclusion and monitor restart.

Questions:

- Is calendar access worth the permission and product scope it introduces?
- After per-application measurement, which call families are reliable enough
  to stop automatically rather than ask?
- Should muting for longer than two seconds count as leaving a call? Core Audio
  reports input IO, not membership in a meeting.
- Should the existing ten-minute silence nudge remain as the final fallback?

The observation-only diagnostic is `quill watch-calls`. It prints changed input
snapshots and stable transitions from the same code path as the menu app. It
does not show notifications or affect recording.

The raw signal, Zen Browser normalization, stable synthetic browser start and
end, notification delivery, initial-state suppression and unknown Voice Memos
handling have been exercised in a signed build. The installed menu app has also
completed the actionable path from a synthetic Zen start prompt through bound
capture to the matching end prompt and clean stop. A solo Zoom meeting passed
join, mute, microphone switching and leave detection; its 115-second recording
captured both tracks without a gap. A solo FaceTime-link call passed join, mute,
normal microphone switching and leave detection. A failed iPhone Continuity
microphone handoff released input for four seconds and produced an end prompt
while the FaceTime call remained active; a normal retry did not. This was a
Continuity microphone failure, not a FaceTime lifecycle failure. Continuity
Phone showed the same stable join, mute and hang-up lifecycle, but the shared
`com.apple.avconferenced` process made the prompt say FaceTime.
Safari Meet initially exposed its microphone through the unrecognized
`com.apple.WebKit.GPU`; normalizing that helper as Safari made the installed
prompt work. Chrome Meet also prompted correctly. Dismissing Chrome's start
prompt and leaving produced neither a recording nor an end prompt. Remaining
browser evidence is mute and device switching during a real meeting. The
application-by-application false-transition rate is not known.

## Live transcription

Quill transcribes after the recording stops: `TranscriptionCoordinator` is a
post-recording queue of session folders, and the companion shows a processing
state until the transcript exists. Granola transcribes during the call and shows
text as it arrives.

The open question is whether Quill should follow. Watching the transcript build
during a meeting is the visible half; the larger consequence is that a live
transcript is the only way to offer anything mid-call, and that a partial
transcript exists if the machine dies before the session is finished.

Against it: streaming recognition is a different engine contract from batch
Parakeet, it runs the model for the whole meeting rather than once at the end,
and the current design deliberately keeps diarisation and speaker naming as a
post-hoc review step over retained source tracks, which a live stream cannot
feed. Whatever is shown live would have to be reconciled with the batch
transcript that follows, or the batch pass has to go, and the batch pass is
what makes re-transcription and speaker separation possible.

Questions:

- Is the live transcript worth showing at all, or is the real prize a mid-call
  capability that does not exist yet?
- Can a streaming pass and the existing batch pass coexist without the user
  seeing two different transcripts of the same meeting?
- What happens to transcript review and voice identification, both of which
  assume a completed recording and both source tracks?

## System-audio tap format changes

`SystemAudioRecorder.attach()` reads `kAudioTapPropertyFormat` once and closes
over that format in the IOProc block. Every later buffer is stamped with it.
Nothing re-reads it, and the recorder raises no invalidation of its own.

A global tap's format follows the output device, so switching default output
mid-meeting, for example AirPods at 24 kHz to built-in speakers at 48 kHz, may
change it under a running IOProc. Unverified.

If it does, two things break silently:

- Buffers that still parse are written at the wrong rate. `TrackWriter`
  compares `buffer.format`, which is the stale stamp, so it never resamples.
- Buffers that fail to parse hit the `guard let buffer` early return. But
  `liveness.mark()` runs before that guard, so `CaptureSupervisor` still sees
  evidence of life and the stall check never fires. The track stops growing for
  the rest of the meeting.

The second holds for any nil buffer, not just a format change, and is fixed
independently by marking liveness after the buffer is built.

To investigate: log `kAudioTapPropertyFormat` on a tick while switching default
output between devices of different sample rates. Granola polls for this
(`checkTapFormatChanged`), which suggests it happens.
