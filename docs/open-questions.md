# Open questions

Possible product paths that need investigation or a design decision. Nothing in
this file is committed roadmap or current behaviour.

## Meeting-aware start and stop

Should Quill offer to start recording when a meeting begins and stop when it
ends, while leaving the decision to record with the person?

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
        show "Possible call" with a tokenized "Start Recording" action

on start action(prompt_token):
    if the token is still current and that app is still confirmed:
        start capture with a new recording token bound to that app

handle_ended(apps):
    if an ended app owns the current bound recording:
        show "Call may have ended" with its recording token

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

Recognized applications can produce a `Possible call` notification with an
explicit `Start Recording` action. Accepting it binds that recording to the
application family. Two seconds of absence from that application produces a
`call may have ended` notification with an explicit `Stop Recording` action.
Manual recordings remain unbound. Unknown processes are diagnostic evidence
only and cannot prompt.

The menu app appends changed raw snapshots to the disposable
`cache/call-detection.log`. `quill watch-calls` runs the same scanner and reducer
as an observation-only test harness; it prints diagnostics and owns no product
notifications or recording actions.

Reducer tests cover initial snapshots, stable start and end, transient input and
overlapping recognized applications. Remaining coverage belongs around helper
PID replacement, loopback exclusion and monitor restart. The integration check
must still run the signed app through a real call start, accepted recording and
hang-up; a mocked process list cannot verify the macOS signal.

Questions:

- Is calendar access worth the permission and product scope it introduces?
- After per-application measurement, which call families are reliable enough
  to stop automatically rather than ask?
- Should muting for longer than two seconds count as leaving a call? Core Audio
  reports input IO, not membership in a meeting.
- Should accepting a detected call also snapshot the per-recording meeting
  profile described below?
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
