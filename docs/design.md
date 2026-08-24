# Quill design

This document describes Quill's implementation and audio data flow. Product
behaviour and interface copy remain authoritative in `docs/ux.md`; the reasons
behind settled choices remain in `docs/decisions.md`.

## 1. What Quill is

Quill is one local macOS process with four responsibilities:

1. capture the microphone and all system playback as independent tracks;
2. maintain a common meeting timeline across device changes and capture gaps;
3. publish playable source, cleaned and mixed audio after recording stops; and
4. transcribe each side independently, then merge their words by timestamp.

It has no server and no database. A session directory is both the durable record
of a meeting and the unit of recovery and queued processing.

## 2. The audio flow

The recorder has two parallel paths. The source path is authoritative and writes
recoverable audio to disk. The live processing path consumes copies of the same
normalized PCM buffers and produces replaceable derivatives.

```text
default microphone                 all system playback
AVAudioEngine tap                  Core Audio process tap
        |                                  |
        v                                  v
     MicRecorder                    SystemAudioRecorder
        |                                  |
        +---------- CaptureSupervisor -----+
        |          rebuilds dead graphs    |
        v                                  v
   TrackWriter                        TrackWriter
   mono, 48 kHz                       mono, 48 kHz
   resample + gaps                    downmix + gaps
        |                                  |
        |                                  |
        v                                  v
 .quill/mic.caf                 .quill/system.caf
 AAC source of truth             AAC source of truth
        |                                  |
        +------- successful PCM writes ----+
                           |
                           v
                 LiveEchoCanceller
                WebRTC AEC3, 10 ms blocks
                    |             |
                    v             v
       .quill/mic-cleaned.caf  .quill/meeting.caf
          cleaned local AAC     mono mixed AAC
                    |             |
                    +------ AudioFinalizer ------+
                           validate and remux
                                  |
        +-------------------------+-------------------------+
        v                         v                         v
 Source Audio/Local.m4a  Source Audio/Local Cleaned.m4a  Meeting Audio.m4a
                                  |
 Source Audio/Remote.m4a ---------+
                                  v
                    TranscriptionCoordinator
                  separate ASR, offset, merge
                                  |
                   .quill/transcript.json
                         transcript.md
```

The arrows into `LiveEchoCanceller` do not reread the CAF files. `TrackWriter`
reports the normalized PCM buffer after its file write succeeds. Live processing
therefore sees the same frames and silence padding as the retained track, before
AAC encoding has altered the samples. The monitor runs synchronously on the
writer queue while the writer lock is held. It cannot undo the accepted frame,
but a slow monitor can delay later source writes and contribute to queue
overflow. Current fan-out is therefore ordered after source acceptance, but not
isolated from it.

### 2.1 Current responsibility boundaries

The runtime is layered by data flow, but several concrete types currently span
more than one architectural responsibility:

| Type | Responsibilities it currently owns |
|---|---|
| `MicRecorder`, `SystemAudioRecorder` | Device graph, callback adaptation, invalidation signals and creation or ownership of the source writer |
| `CaptureSupervisor` | Stall detection, graph restart policy and outage state |
| `TrackWriter` | PCM copying, normalization, timeline repair, AAC persistence, level state and live fan-out |
| `LiveEchoCanceller` | Stream alignment, AEC3, meeting mixing, two AAC encoders and internal publication |
| `RecordingSession` | Lifecycle orchestration, journal and metadata creation, alerts and live-processing coordination |
| `AudioFinalizer` | Recovery, validation, remuxing, fallback DSP, mixing, artifact publication and metadata transition |
| `TranscriptionCoordinator` | Job queue, fallback AEC, ASR orchestration, transcript assembly, hooks and retention handoff |

These are accurate descriptions of the code, not the desired final layer
boundaries. The first seam to preserve is the one already implicit inside
`TrackWriter`: the AAC encoder has accepted a normalized frame with a stable
track position, and that frame is now available to optional consumers. This is
a process-crash recovery boundary, not an `fsync` or power-loss guarantee.
Section 10 (Critique surface) and `docs/open-questions.md` describe how that seam
can admit future live transcription without changing capture or recovery.

## 3. Capture and timeline ownership

### 3.1 Capture graphs

`MicRecorder` uses an `AVAudioEngine` input tap. The input format follows the
active device and can change when a route changes.

`SystemAudioRecorder` uses a private Core Audio process tap connected through a
private aggregate device. It captures the global playback mix, including audio
outside the meeting application. The tap commonly supplies stereo at the output
device's sample rate.

Each recorder owns only its capture graph. A `CaptureSupervisor` owns restart
policy. It treats five seconds without a buffer as a stalled graph, tears the
graph down, and retries with capped exponential backoff. Reattachment keeps the
existing `TrackWriter`, so a device change does not create another file or reset
the track clock.

### 3.2 TrackWriter is the normalization boundary

Both capture graphs feed a `TrackWriter` fixed at mono, 48 kHz, float PCM on its
input side and AAC in a CAF container on disk. It:

- copies in the realtime callback and performs conversion and disk IO on a
  private serial queue;
- explicitly averages multichannel input before conversion;
- keeps an `AVAudioConverter` until the source format changes;
- records the wall-clock arrival of the first and latest buffers;
- pads observed capture gaps and an early-ending track with silence; and
- reports only successfully written normalized buffers to the live monitor.

The first AAC write failure is terminal for that source writer. It closes the
encoder, leaves prior bytes for a recovery attempt and reports once to
`RecordingSession`; later capture buffers for that writer are ignored. The
session becomes degraded, abandons live AEC and mixing, and continues its
surviving source. Failure of both source writers stops the session
automatically. Normal stop omits an empty failed source from metadata and
retains a nonempty partial source for finalization. A session with no
successfully archived frames receives terminal `audio_state: empty` metadata
and does not enter audio finalization or transcription, including after restart.

CAF is the active container because already-written AAC remains usable if the
process dies. M4A is reserved for the finished, human-facing layout.

### 3.3 The common clock

The two files each begin at their own first buffer. `RecordingSession` records
how many milliseconds each first buffer followed the earlier one as
`start_offset_ms`. Within a track, silence padding makes frame `n` continue to
mean `firstBufferAt + n / 48000`, including across capture outages.

This creates a global meeting position:

```text
global position = track start offset + track frame / 48000
```

AEC alignment, the meeting mix and transcript merging all use this same model.
The model is based on buffer arrival `Date` values and accumulated frame counts,
not the audio devices' host-time timestamps. Live AEC rounds the full-precision
first-buffer difference directly to samples. Metadata truncates that difference
to milliseconds, and offline AEC, mixing and transcript merging use the stored
millisecond value. The paths therefore share the model but not an identical
sample offset.

Gap repair only inserts silence when accumulated frames fall sufficiently behind
elapsed wall time. It does not trim overlapping frames, correct a fast source
clock or estimate long-term drift between devices. `Date` is also not a
monotonic audio clock.

### 3.4 Capture journal

Before either graph starts, `RecordingSession` atomically writes
`.quill/capture.json` with the intended files and provisional offsets. It updates
the journal after both first-buffer times are known. A normal stop writes the
richer `.quill/meta.json` and removes the journal. If the process is interrupted,
the finalizer can derive missing end time and durations from the surviving CAF
files and publish recovered metadata. If both CAFs are readable but contain no
frames, it publishes terminal `audio_state: empty` metadata and removes the
journal instead of retrying the empty capture on every launch.

## 4. Processing during recording

`LiveEchoCanceller` is one optional monitor attached to both `TrackWriter`s. It
does not own either source file and cannot damage them.

It waits until both first-buffer times establish the track offset, then aligns
the normalized microphone (near) and system (far) streams. WebRTC AEC3 processes
mono 10 ms frames. The bridge reports zero internal buffer delay because Quill
has already aligned the two streams.

The same pass produces two AAC/CAF derivatives:

- `mic-cleaned.caf`: the microphone after correlated system playback is removed;
- `meeting.caf`: `(cleaned microphone + system) * 0.7071`, clamped to the PCM
  range and encoded as mono AAC at 64 kbit/s.

The meeting mix includes a far-only prefix or tail when the system track extends
beyond the microphone track. The cleaned track follows the microphone length.

The live path is bounded and fail-open:

- it waits at most five seconds for lagging far-end audio before using silence;
- it abandons if unprocessed microphone audio reaches 30 seconds;
- a format, ordering, AEC or derivative-write failure abandons the live pass;
- partial derivative files are removed; and
- the two source CAF files continue recording unchanged.

On stop, the source writers drain and pad to the shared wall-clock end first.
`LiveEchoCanceller.finish()` then drains its queue, closes both AAC writers and
renames both live partials to their internal final names. A normal publication
makes both available. Because the two renames are sequential, a failure on the
second can leave the first available for the finalizer to discover independently.

## 5. Audio finalization

`AudioFinalizer` is an actor with a per-session single-flight task. Swift actors
are reentrant whenever finalization awaits an export, so actor isolation alone
would not serialize whole operations. A duplicate request for the same session
awaits its existing task; different sessions may progress independently. The
finalizer runs after `RecordingSession.stop()` and before normal transcription.
On launch it first scans for interrupted or unfinished sessions, finalizes them,
then queues sessions without transcripts.

Finalization is restartable and follows these stages:

1. Read `meta.json`, or reconstruct it from `capture.json` and surviving CAFs.
2. Passthrough-remux source AAC from CAF into `Source Audio/Local.m4a` and
   `Source Audio/Remote.m4a`. This changes the container, not the encoded audio.
3. Use the live cleaned microphone if present. Otherwise rerun AEC3 offline from
   the retained source tracks and their offsets. AEC failure falls back to the
   raw microphone for the meeting mix.
4. Passthrough-remux the cleaned microphone into
   `Source Audio/Local Cleaned.m4a` when one exists.
5. Validate the live meeting mix against the expected global duration and use
   it when valid. Otherwise stream an offline mono mix from the cleaned or raw
   microphone plus system audio at their offsets.
6. Atomically rewrite `meta.json` with human-facing paths and
   `audio_state: finalized`.
7. Remove the capture journal and internal CAF inputs that have published
   successors.

Every M4A is first written under a unique internal partial name. Before it is
moved into place, the finalizer checks duration and decodes the complete file.
An existing valid output is reused on retry. The metadata write is the point at
which the set of published paths becomes authoritative.

The files themselves are published one at a time before that metadata write.
A crash can therefore leave a mixture of old metadata and valid new outputs;
the next pass validates and reuses those outputs rather than treating the
directory rename sequence as one filesystem transaction.

## 6. Transcription and later processing

`TranscriptionCoordinator` is a serial in-memory work queue backed by filesystem
state. A directory with `meta.json` but no `.quill/transcript.json` is pending
and is re-enqueued on launch.

For a baseline transcript it:

1. resolves source paths and offsets from `meta.json`;
2. uses the published cleaned microphone when available;
3. independently retries offline AEC if the cleaned microphone is missing;
4. transcribes microphone and system tracks separately;
5. shifts each segment by its track's start offset;
6. merges segments by global timestamp with coarse `Me` and `Them` identities;
7. atomically publishes canonical `.quill/transcript.json` and rendered
   `transcript.md`; and
8. runs the configured `on_stop` command, then applies source-audio retention.

One bad or missing track is logged and skipped rather than discarding a usable
transcript from the other. If audio finalization failed immediately after stop,
transcription is still enqueued and can operate on paths that remain valid in
metadata. This is degraded operation, not the normal path.

Optional speaker separation happens later against retained source audio. It
updates speaker attribution in the existing timed document without rerunning
speech recognition.

## 7. Session artifacts and authority

| Artifact | Role | Authoritative? | Recovery treatment |
|---|---|---:|---|
| `.quill/mic.caf` | Normalized microphone capture | Yes until source M4A publication | Never modified by AEC |
| `.quill/system.caf` | Normalized global playback capture | Yes until source M4A publication | Never modified by AEC |
| `.quill/capture.json` | Interrupted-capture journal | Temporarily | Reconstructs `meta.json` |
| `.quill/mic-cleaned.caf` | Live or offline AEC derivative | No | Rebuildable from sources |
| `.quill/meeting.caf` | Live mono mix derivative | No | Validated or rebuilt |
| `.quill/meta.json` | Current paths, offsets and capture facts | Yes | Atomically replaced |
| `Source Audio/*.m4a` | Finished retained sources and cleaned local track | Yes after finalization | Validated and reused |
| `Meeting Audio.m4a` | Human playback and sharing artifact | Derived | Rebuilt while sources remain |
| `.quill/transcript.json` | Canonical transcript and speaker data | Yes | Marks transcription complete |
| `transcript.md` | Human-readable transcript | Derived | Rendered from canonical JSON |

Retention removes `Source Audio/` only after canonical transcript publication
and after `on_stop` terminates. It retains the meeting mix, metadata, logs and
transcripts, but removes the material needed for later AEC, re-transcription or
speaker samples.

## 8. Invariants

The implementation relies on these cross-layer invariants:

- both source writers produce mono 48 kHz timelines;
- a track's frame positions remain monotonic across graph rebuilds;
- gaps are silence in the retained track and in live processing;
- every consumer uses the same track-start relationship, while the current live
  and persisted paths quantize that relationship differently;
- live derivatives are never substitutes for retained sources;
- a derivative is published only after its encoder closes cleanly;
- metadata paths, rather than filename inference, select downstream inputs; and
- `transcript.json`, not `transcript.md`, marks successful transcription.

Changing a sample rate, channel layout, gap rule, clock source or offset
definition is therefore a system-wide audio change, even if its code appears
inside one recorder.

## 9. Verification boundaries

Unit tests exercise timeline padding, terminal source-write failure, finalizer
retry and single-flight behavior, rejection of truncated cleaned audio, finished
layout, mono meeting output, and the choice between live and offline meeting
artifacts.

The hidden `check-live-aec` command adds an integration path. Synthetic mode
feeds controlled near and far signals through real `TrackWriter` monitors and
`LiveEchoCanceller`; replay mode streams retained real-session audio through the
same path and compares its AEC result with a previously published offline result.
With `--finalize`, it also invokes the production `AudioFinalizer` and validates
the published meeting file.

That command does not exercise the physical `AVAudioEngine` tap, the Core Audio
process tap, capture-graph rebuilding, the menu/UI stop path, TCC permission
state, or signing entitlements. A signed live recording remains the end-to-end
test for those boundaries.

## 10. Critique surface

These are the places where an architectural review has the most leverage. They
describe current tradeoffs, not established defects or settled changes.

1. **Responsibility concentration.** `TrackWriter`, `LiveEchoCanceller`,
   `AudioFinalizer` and `TranscriptionCoordinator` each combine orchestration
   with media processing or persistence. Adding another live consumer directly
   to those types would make lifecycle, timing and failure policy harder to
   reason about.
2. **Clock quality.** Alignment uses non-monotonic wall-clock buffer arrival and
   one-sided silence correction. It does not use Core Audio host timestamps,
   correct overlap or estimate long-term drift between independent device
   clocks. Live and persisted offsets also use different quantization.
3. **Retained source fidelity.** The durable source of truth is lossy AAC, not
   PCM. Live derivatives start from pre-encode PCM; offline recovery decodes AAC
   before AEC and mixing, so the two paths are deliberately comparable but not
   sample-identical.
4. **Capture scope.** The system track is the global playback mix. This is simple
   and app-independent, but unrelated sounds become meeting audio and the AEC
   reference.
5. **Coupled derivatives.** Cleaned microphone and meeting mix share one live
   worker and publication result. Failure of either moves both to the offline
   path, which simplifies recovery at the cost of fault isolation.
6. **Backpressure policy.** A capture callback may drop input after 256 queued
   buffers. The next accepted buffer turns elapsed wall time into a silent gap.
   This preserves timing while losing content, and makes slow storage a quality
   failure rather than an unbounded-memory failure. The synchronous monitor can
   delay the archive queue, and a future bounded consumer contract still needs
   to define what stateful AEC or ASR does after a dropped frame.
7. **Publication boundary.** Individual M4As precede the atomic metadata update.
   Recovery is idempotent, but the session directory is not transactionally
   replaced as a unit.
8. **Stop latency.** Source queues and the live AEC queue are drained
   synchronously during `RecordingSession.stop()`. Normal operation leaves
   little work, but a near-limit backlog can delay the UI's transition into
   asynchronous finalization.
9. **Best-effort degradation.** AEC or one-track transcription failure produces
   the best remaining artifact and records the loss in logs. This favors getting
   a result, but quality degradation is less visible than total capture failure.
10. **Duplicated recovery responsibility.** Both `AudioFinalizer` and
    `TranscriptionCoordinator` can run offline AEC. This protects transcription
    after partial finalization, while creating two orchestration sites for the
    same fallback.
11. **Health versus metering.** Audible-level reporting is optional product
    state, but exact digital silence on the microphone can trigger capture graph
    rebuilding. A future consumer split must keep capture-health evidence on a
    reliable path rather than treating all level analysis as droppable metering.

## 11. What this design is not

- It is not per-application system capture.
- It is not a multichannel archival recorder.
- It is not a lossless audio pipeline.
- It does not infer exact people during baseline transcription.
- It does not require live AEC or a live mix for source capture to succeed.
- It does not treat the human-facing meeting mix as sufficient recovery input.
