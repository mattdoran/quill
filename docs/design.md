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

`AppController` owns the status-menu actions and shares one
`ApplicationPresenceController` across every user-facing Quill window, panel,
alert and Sparkle session. That controller keeps the application regular while
any of those surfaces exists and restores accessory mode only after the last
one closes. The meeting companion is transient status UI and does not
participate in this window-presence lifecycle.

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
                    AcceptedFrame
            typed track, frame position, PCM
                           |
                           v
              fan-out + bounded AEC mailbox
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
AAC encoding has altered the samples. `AcceptedFrame` copies the mono PCM with a
typed track identity and track-local start frame. An immutable fan-out offers it
to a bounded mailbox for each consumer. Consumer code runs on the mailbox queue,
never on the source writer queue. If the AEC mailbox fills, it abandons the live
pass and source recording continues.

### 2.1 Current responsibility boundaries

The runtime is layered by data flow, but several concrete types currently span
more than one architectural responsibility:

| Type | Responsibilities it currently owns |
|---|---|
| `MicRecorder`, `SystemAudioRecorder` | Device graph, callback adaptation, invalidation signals and creation or ownership of the source writer |
| `CaptureSupervisor` | Stall detection, graph restart policy and outage state |
| `TrackWriter` | PCM copying, normalization, timeline repair, AAC persistence, level state and accepted-frame production |
| `AcceptedFrameFanout`, `AcceptedFrameMailbox` | Per-consumer queue isolation and bounded overload policy |
| `LiveEchoCanceller` | Stream alignment, AEC3, meeting mixing, two AAC encoders and internal publication |
| `RecordingSession` | Lifecycle orchestration, typed journal and manifest creation, alerts and live-processing coordination |
| `SessionManifest`, `SessionMetadataStore` | Persisted capture and session schema, compatibility defaults and atomic JSON IO |
| `AudioPreparation` | Safe source resolution, cleaned-input validation, offline AEC and raw-microphone fallback |
| `AudioFinalizer` | Recovery, remuxing, offline mixing, artifact publication and typed metadata transition |
| `TranscriptionCoordinator` | Job queue, ASR orchestration over prepared inputs, transcript assembly, hooks and retention handoff |

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
the track clock. A system-track capture gap also forces a process-tap rebuild:
buffers resuming only proves transport liveness, and a HAL overload can leave
the existing tap delivering a degraded signal. Default output changes rebuild
the process tap rather than relying on its private aggregate device to adapt.

### 3.2 TrackWriter is the normalization boundary

Both capture graphs feed a `TrackWriter` fixed at mono, 48 kHz, float PCM on its
input side and AAC in a CAF container on disk. It:

- copies in the realtime callback and performs conversion and disk IO on a
  private serial queue;
- explicitly averages multichannel input before conversion;
- keeps an `AVAudioConverter` until the source format changes;
- records the wall-clock arrival of the first and latest buffers;
- pads observed capture gaps and an early-ending track with silence; and
- offers only successfully written normalized buffers to accepted-frame consumers.

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

The two files each begin at their own first buffer. `SessionTimeline` rounds how
many milliseconds each first buffer followed the earlier one to the nearest
millisecond and records that once as `start_offset_ms`. Within a track, silence
padding makes frame `n` continue to mean `firstBufferAt + n / 48000`, including
across capture outages.

This creates a global meeting position:

```text
global position = track start offset + track frame / 48000
```

The capture journal, session manifest, live and offline AEC, meeting mix and
transcript merging all use this same rounded-millisecond model. At 48 kHz its
resolution is 48 frames. Accepted frames retain their track-local frame
position and identify whether their samples were captured or inserted as
silence.

The active alignment model is based on buffer arrival `Date` values and
accumulated frame counts. It does not yet use the audio devices' timestamps to
alter captured audio. For diagnosis, both recorders retain the callback's
device sample position and Core Audio host time once per minute and at the first
buffer of every route epoch. `TrackWriter` adds the corresponding normalized
48 kHz frame position after the source write succeeds.

The sparse observations land in `.quill/clock-observations.jsonl`. At stop,
Quill fits device and normalized frame rate against the common monotonic host
clock for each uninterrupted capture segment within a route, then writes rate error, timing residual and
relative microphone-to-system drift to `session.log`. Diagnostics are
non-authoritative and fail open: capture continues if their file cannot be
written. They measure the current contract without correcting it.

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

While their encoders are open these are named `mic-cleaned.caf.live` and
`meeting.caf.live`. The final `.live` suffix marks incomplete, unpublished
working files; the bytes are still an AAC stream in a CAF container. A clean
finish closes the encoders and renames them to `.caf`. Finalization later
remuxes the closed CAF files to human-facing M4A.

The meeting mix includes a far-only prefix or tail when the system track extends
beyond the microphone track. The cleaned track follows the microphone length.

The live path is bounded and fail-open:

- its mailbox abandons the pass if 30 seconds of accepted PCM awaits delivery;
- it waits at most five seconds for lagging far-end audio before using silence;
- it abandons if unprocessed microphone audio reaches 30 seconds;
- a format, ordering, AEC or derivative-write failure abandons the live pass;
- partial derivative files are removed; and
- the two source CAF files continue recording unchanged.

A system capture gap or output-route change resets AEC3 after the process tap
is rebuilt. Once per minute, the session log records aggregate near, reference
and cleaned RMS plus achieved attenuation. This distinguishes a live graph from
a useful reference and makes a persistent cancellation failure diagnosable
without logging realtime buffers.

On stop, the realtime graphs detach on the main actor. Both source writers then
drain concurrently and pad to the shared wall-clock end while the main actor is
suspended. The accepted-frame mailbox drains before `LiveEchoCanceller.finish()`
drains the processor queue, closes both AAC writers and renames both live
partials to their internal final names. Manifest IO also runs off-main. A normal
publication makes both derivatives available. Because the two renames are
sequential, a failure on the second can leave the first available for the
finalizer to discover independently.

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
3. Ask `AudioPreparation` for the validated cleaned microphone. It uses the
   live result when valid, otherwise reruns AEC3 offline from retained sources.
   AEC failure returns the raw microphone for mixing and transcription.
4. Passthrough-remux the cleaned microphone into
   `Source Audio/Local Cleaned.m4a` when one exists.
5. Check the live meeting mix against the expected global duration and use it
   when valid. Otherwise stream an offline mono mix from the cleaned or raw
   microphone plus system audio at their offsets. The published M4A is decoded
   completely, so the live CAF is not also decoded completely before remux.
6. Atomically rewrite `meta.json` with human-facing paths and
   `audio_state: finalized`.
7. Remove the capture journal and internal CAF inputs that have published
   successors.

Every M4A is first written under a unique internal partial name. Before it is
moved into place, the finalizer checks duration and decodes the complete file.
An existing valid output is reused on retry. The metadata write is the point at
which the set of published paths becomes authoritative.

The finalization log records elapsed time for Local, Remote, Local Cleaned,
Meeting Audio and the complete operation. Remuxes currently run serially. They
are independent media operations, but parallel full-file reads require a
benchmark before increasing IO contention.

The files themselves are published one at a time before that metadata write.
A crash can therefore leave a mixture of old metadata and valid new outputs;
the next pass validates and reuses those outputs rather than treating the
directory rename sequence as one filesystem transaction.

## 6. Transcription and later processing

`TranscriptionCoordinator` is a serial in-memory work queue backed by filesystem
state. A directory with `meta.json` but no `.quill/transcript.json` is pending
and is re-enqueued on launch.

For a baseline transcript it:

1. reads typed source paths and offsets from `meta.json`;
2. consumes the validated cleaned or raw inputs from `AudioPreparation`;
3. transcribes microphone and system tracks separately;
4. shifts each segment by its track's start offset;
5. merges segments by global timestamp with coarse `Me` and `Them` identities;
6. atomically publishes canonical `.quill/transcript.json` and rendered
   `transcript.md`; and
7. runs the configured `on_stop` command, then applies source-audio retention.

One bad or missing track is logged and skipped rather than discarding a usable
transcript from the other. If audio finalization failed immediately after stop,
transcription is still enqueued and can operate on paths that remain valid in
metadata. This is degraded operation, not the normal path.

Optional speaker separation happens later against retained source audio. The
normal call path analyzes only Remote and preserves the coarse local `Me`
identity. Local analysis is an explicit in-room option. It updates speaker
attribution in the existing timed document without rerunning speech recognition.
The coordinator logs the prepared input's actual filename, not the source path
from the manifest. Local and remote model passes are serial.

Before publishing the first separated document, `TranscriptStore` atomically
preserves the baseline as
`.quill/transcript-before-speaker-separation.json`. Undo republishes that
snapshot as canonical JSON and Markdown, then removes the snapshot. A later
separation pass reads that baseline but does not replace the current separated
document until the new result succeeds. A failed analysis therefore leaves the
canonical transcript unchanged.

Long-form separation uses FluidAudio's offline VBx pipeline. The user supplies
the exact number of speakers on the selected track, or explicitly chooses less
reliable automatic detection. Segmentation and embedding extraction run over
10-second chunks and expose completed/total chunk progress. Clustering remains
an indeterminate final stage. The diarization model output is then mapped onto
the existing ASR segments by greatest time overlap.

## 7. Session artifacts and authority

| Artifact | Role | Authoritative? | Recovery treatment |
|---|---|---:|---|
| `.quill/mic.caf` | Normalized microphone capture | Yes until source M4A publication | Never modified by AEC |
| `.quill/system.caf` | Normalized global playback capture | Yes until source M4A publication | Never modified by AEC |
| `.quill/capture.json` | Interrupted-capture journal | Temporarily | Reconstructs `meta.json` |
| `.quill/clock-observations.jsonl` | Sparse device and normalized clock anchors | No | Diagnostic only; capture does not depend on it |
| `.quill/mic-cleaned.caf` | Live or offline AEC derivative | No | Rebuildable from sources |
| `.quill/meeting.caf` | Live mono mix derivative | No | Validated or rebuilt |
| `.quill/meta.json` | Current paths, offsets and capture facts | Yes | Atomically replaced |
| `Source Audio/*.m4a` | Finished retained sources and cleaned local track | Yes after finalization | Validated and reused |
| `Meeting Audio.m4a` | Human playback and sharing artifact | Derived | Rebuilt while sources remain |
| `.quill/transcript.json` | Canonical transcript and speaker data | Yes | Marks transcription complete |
| `.quill/transcript-before-speaker-separation.json` | Exact undo snapshot for optional speaker analysis | Temporarily | Restored through `TranscriptStore`, then removed |
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
- every consumer uses the same rounded-millisecond track-start relationship;
- live derivatives are never substitutes for retained sources;
- a derivative is published only after its encoder closes cleanly;
- metadata paths, rather than filename inference, select downstream inputs; and
- `transcript.json`, not `transcript.md`, marks successful transcription.

Changing a sample rate, channel layout, gap rule, clock source or offset
definition is therefore a system-wide audio change, even if its code appears
inside one recorder.

## 9. Verification boundaries

Unit tests exercise timeline padding, terminal source-write failure, isolation
from a stalled live consumer, finalizer retry and single-flight behavior,
rejection of truncated cleaned audio, finished layout, mono meeting output, and
the choice between live and offline meeting artifacts.

The hidden `check-live-aec` command adds an integration path. Synthetic mode
feeds controlled near and far signals through the real `TrackWriter`,
accepted-frame mailbox and `LiveEchoCanceller`; replay mode streams retained
real-session audio through the same path and compares its AEC result with a
previously published offline result. With `--finalize`, it also invokes the
production `AudioFinalizer` and validates the published meeting file.

That command does not exercise the physical `AVAudioEngine` tap, the Core Audio
process tap, capture-graph rebuilding, the menu/UI stop path, TCC permission
state, or signing entitlements. A signed live recording remains the end-to-end
test for those boundaries.

### 9.1 Signed update boundary

Sparkle is retained by `AppController` and uses its standard update interface.
It checks the HTTPS appcast periodically and exposes the same operation through
the menu. Stable clients use the default appcast channel; beta bundles opt into
both `beta` and default items through a bundle-only channel marker. An update
may be discovered during capture, but its relaunch handler stays behind
`UpdateRelaunchGate` until source archives close and recoverable capture state
is on disk.

The source plist carries a development train such as `0.4.0-dev`. Ordinary
development bundles use the first-parent commit count for Sparkle's strictly
increasing numeric build. A release tag selects `0.4.0-beta.N` or `0.4.0` for
the output bundle and supplies its explicit trunk or maintenance build. Every
beta and stable release packages that bundle twice: a DMG for first installation
and a ZIP referenced by the appcast. Both contain the complete app, including
`Sparkle.framework`. Developer ID signing and Apple notarization protect both;
Sparkle EdDSA additionally signs the updater ZIP.

`release.sh build` is local-only and produces a receipt binding both artifacts
to their tag, commit, build and hashes, plus the ZIP's Sparkle signature.
`release.sh publish` verifies that receipt before creating the tag and GitHub
Release. The appcast is published last, so a client cannot discover an archive
that is not already public and verified.

Builds use the Apple Swift compiler selected by `xcrun` from the active Command
Line Tools installation. The release script permits an explicit `SWIFT`
override for CI, but local builds do not carry a second project toolchain
selection.
Quill retains release optimization but disables whole-module optimization for
its executable target, allowing the compiler to schedule its source files in
parallel. Dependency products retain their own release build settings.
The test target pins the official Swift Testing source release matching this
compiler generation. Apple Command Line Tools ships a Testing framework, but
its SwiftPM integration cannot import and discover this suite reliably. The
test product links CLT's separately installed `_TestingInterop` support library.
Normal tests use SwiftPM's debug configuration. A release-configured test run
must use a separate scratch directory because `-enable-testing` changes release
module fingerprints and would contaminate the production build cache.
`build.sh` selects Apple Swift through `xcrun` and explicitly disables colored
diagnostics. This keeps terminal, agent and CI compiler fingerprints identical
while sharing the normal SwiftPM build directory.

## 10. Critique surface

These are the places where an architectural review has the most leverage. They
describe current tradeoffs, not established defects or settled changes.

1. **Responsibility concentration.** `TrackWriter`, `LiveEchoCanceller`,
   `AudioFinalizer` and `TranscriptionCoordinator` each combine orchestration
   with media processing or persistence. Accepted-frame delivery and persisted
   session state now have explicit owners, but the remaining lifecycle and
   publication boundaries are still broad.
2. **Clock quality.** Alignment uses non-monotonic wall-clock buffer arrival and
   one-sided silence correction. Quill now measures Core Audio host timestamps
   and long-term rate error, but does not use those observations to correct
   overlap or drift between independent device clocks. All consumers share one
   rounded-millisecond offset, which does not improve the underlying clock
   source.
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
   failure rather than an unbounded-memory failure. Each optional consumer also
   needs an explicit mailbox overflow outcome. AEC abandons its live pass;
   future ASR must choose abandonment, reset or retained-source replay.
7. **Publication boundary.** Individual M4As precede the atomic metadata update.
   Recovery is idempotent, but the session directory is not transactionally
   replaced as a unit.
8. **Best-effort degradation.** AEC or one-track transcription failure produces
   the best remaining artifact and records the loss in logs. This favors getting
   a result, but quality degradation is less visible than total capture failure.
9. **Health versus metering.** Audible-level reporting is optional product
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
