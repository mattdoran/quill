# Open questions

Possible product paths that need investigation or a design decision. Nothing in
this file is committed roadmap or current behaviour.

## Speaker diarization beyond four remote people

The pinned offline Sortformer model has four output slots per source track. A
3:42 call with more than eight remote participants confirmed that it merges
identities once Remote contains more than four people. More CPU or parallel
track processing cannot remove that representational limit.

Benchmark FluidAudio's higher-capacity diarizers against retained real calls.
LS-EEND supports more simultaneous speakers but may trade stable identity for
false alarms. The offline VBx pipeline is intended for batch-quality
diarization and clustering. Compare speaker-count accuracy, identity stability,
overlap handling, runtime, peak memory and packaging cost before changing the
model. Also benchmark two concurrent model instances separately; concurrency is
a latency and memory question, not a quality solution.

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

Live transcription is not current scope. The settled constraint is that audio
layers must not prevent it: a future streaming consumer should attach after
normalization and source encoder acceptance without entering either device
capture implementation or changing interrupted-session recovery.

### Practical boundary direction

This is a direction for incremental separation, not a request to build a generic
audio graph now.

| Layer | Owns | Must not own |
|---|---|---|
| Capture adapter and supervision | Device graph, callback adaptation, restart policy and outage state | File layout, AEC or ASR |
| Recorded track | Normalization, timeline repair, source archive and capture health | Optional consumer execution |
| Accepted-frame delivery | Typed immutable frames, fan-out and per-consumer bounded mailboxes | DSP or publication |
| Live processor and derivative sink | Alignment, AEC, mixing and internal live artifacts | Source archive or session metadata |
| Session, publication and transcription coordinators | Lifecycle, recovery, visible artifacts and ASR jobs | Device graphs |

The intended future flow is:

```text
capture adapter
      |
      v
track timeline: mono 48 kHz, track-local frame position, explicit silence
      |
      v
source archive: encoder accepts frame
      |
      v
accepted-frame fan-out
      |
      +--> live AEC --> cleaned-mic stream --> artifact sink
      |                                  +--> optional streaming ASR
      +--> system stream ----------------+--> optional streaming ASR
      +--> metering and health consumers
```

Source acceptance before fan-out retains today's conservative ordering: a live
transcript does not run ahead of the recoverable CAF stream accepted by the
encoder. This is not a power-loss durability guarantee. The write adds little
meaningful latency for meeting transcription.

Source rejection is already terminal per track: the archive closes, the session
becomes degraded, live derivatives stop, and the surviving source continues.
Failure of both archives stops the session. Future fan-out must preserve this
session-owned policy rather than turning storage failure into a consumer event.

The accepted-frame fan-out and AEC mailbox now perform only bounded enqueueing
on the writer queue; consumer code runs elsewhere. Every additional consumer
still needs its own overload contract. A missing frame may make a meter skip an
update, but stateful ASR must explicitly abandon, reset with a discontinuity or
recover by replaying retained source audio.

Track-local frame positions remain the audio contract. Microphone and system
ASR can begin independently; their hypotheses acquire the existing
`start_offset_ms` only when merged onto the meeting timeline. This avoids making
either capture stream wait for the other merely so transcription can start.

The current clock contract is explicit: `SessionTimeline` rounds first-buffer
arrival offsets to the nearest millisecond, every live and persisted consumer
uses those offsets, track positions count normalized 48 kHz frames, and accepted
frames distinguish captured audio from inserted silence. It neither trims
overlap nor corrects long-term device drift.

Quill now records sparse device-sample, Core Audio host-time and normalized-frame
anchors for each route epoch. Replacing wall-clock alignment or adding a drift
policy remains conditional work. The observations must first show whether drift
is material, whether it is linear within a route, and whether Apple's system-tap
drift compensation already stabilizes that source.

Live AEC complicates microphone input selection. A streaming engine could use
the cleaned stream and need a reset or replay if AEC abandons, or use raw
microphone audio live and reconcile against cleaned audio after stop. That is an
engine and product-quality decision, not a capture responsibility.

### Incremental path that does not build the feature

No refactor is justified solely by the possibility of live transcription. The
canonical accepted frame, isolated delivery seam, typed session manifest and
shared offline audio preparation now exist. Remaining work should happen only
when an adjacent requirement reaches it:

1. Separate live processing from derivative publication when either needs an
   independent implementation or failure policy.
2. Keep batch transcription unchanged until a real streaming engine is selected.

At that point adding live ASR is a new consumer and transcript lifecycle, not a
third recorder.

### Decisions deliberately left open

Streaming recognition is a different engine contract from batch Parakeet. It
runs the model throughout the meeting and emits hypotheses that may be revised.
The current document model assumes completed segments and post-hoc speaker
review over retained source tracks.

Do not choose provisional transcript storage yet. If crash-surviving live text
becomes a requirement, it needs one per-session authoritative store with an
explicit incomplete-to-final lifecycle. Whether that is an append-only file or
a database depends on the revision and query model of the selected engine; a
collection of loosely related JSON sidecars is not the default.

Questions:

- Is the live transcript worth showing at all, or is the real prize a mid-call
  capability that does not exist yet?
- Does live text need to survive a process crash, or is retained audio plus
  post-stop recovery sufficient?
- Does a streaming engine emit immutable finalized spans, revisable hypotheses,
  or both?
- Can a streaming pass and the existing batch pass coexist without the user
  seeing two different transcripts of the same meeting?
- Should live microphone ASR consume raw audio for continuity or cleaned audio
  for quality when AEC can abandon?
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
