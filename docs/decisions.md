# Decision log

Dated product and architecture decisions. Newest first.

## 2026-09-01: Stamp development bundles with trunk build order

**Decision:** `bundle.sh` derives `CFBundleVersion` from master's first-parent
count whenever the effective version ends in `-dev` and no explicit build was
supplied. The shared derivation rejects a development build that is not newer
than every published appcast build. Explicit release builds retain
`release.sh`'s trunk or maintenance number.

**Why:** The source plist placeholder build `4` leaked into an installed
`0.5.0-dev` bundle while stable `0.4.0` was appcast build `95`. Sparkle correctly
compares `CFBundleVersion` and therefore offered what looked like a
marketing-version downgrade. The earlier release decision described first-parent
ordering but implemented it only in `release.sh`, not the ordinary bundle path
used for local installs.

**Consequence:** A current development checkout uses its first-parent build and
no longer sees stable build `95` as an update. The source plist remains a
placeholder; the bundle artifact is authoritative.

## 2026-09-01: Keep every user-facing window recoverable

**Decision:** One application-level presence controller owns Quill's activation
policy. Any Settings, transcript, chooser, alert, About or Sparkle surface makes
Quill a regular application until the last such surface closes. A conditional
`Show Quill Window` menu command raises the existing surface. Open panels are
asynchronous, reused while open and block other window-producing menu commands.

**Why:** A transcript window, recording chooser and Sparkle prompt accumulated
behind one another while Quill was absent from Command-Tab. Each action had
executed, but the accessory application had no discoverable route back to its
modal UI. The earlier implementation assigned activation policy only to the
transcript controller, so overlapping surfaces had no shared lifecycle.

**Consequence:** This broadens the 2026-08-20 task-window decision from
transcript review to every user-facing Quill surface. The Dock presence remains
temporary, but closing one window cannot hide another, and a chooser cannot be
stacked by repeating its menu action.

## 2026-08-28: Remember companion placement across sessions

**Decision:** Dragging the meeting companion sets its position for later
sessions and application launches. Persist its right edge and vertical centre
so expanded and collapsed states share one anchor. If that position is no
longer on a connected display, use the default top-right position.

**Why:** The top-right is shared by native notifications, call overlays and
other meeting tools. Resetting Quill there for every session repeatedly hides
the `Record` action after the person has already moved it somewhere usable.

**Consequence:** This supersedes the 2026-08-20 session-scoped placement
decision. Dragging is now a durable preference, while display changes still
keep the companion on-screen.

## 2026-08-27: Use exact-count VBx for long-form voice separation

**Decision:** Optional voice separation uses FluidAudio's offline VBx pipeline.
Before each pass, ask for the number of distinct speakers on the selected audio
track. Exact counts from 2 through 20 are the normal path; automatic detection
is available and labelled less reliable. A separated transcript can be rerun
from its preserved baseline without first publishing an undo.

**Why:** On a human-labelled 50:43 remote track with three speakers, the
existing offline Sortformer reached 44.9% duration accuracy and mixed all three
people across its slots. Exact-count VBx reached 95.2%. Stateful high-context
Sortformer reached 93.7% but exposes four fixed slots and still requires an
unproven merge step. Automatic VBx chose four clusters and reached 93.2%.

**Consequence:** The speaker-count hint constrains clustering rather than the
global capacity of the model. VBx reports real completed/total segmentation
chunks, which Quill displays as percentage progress. The following clustering
stage remains indeterminate. A failed rerun leaves both the preserved baseline
and currently published separated transcript intact.

## 2026-08-26: Do not show false diarisation progress

**Decision:** Speaker separation uses an indeterminate activity indicator and
names the selected audio source. It does not show a percentage or source count.

**Why:** Sortformer exposes no progress during its single, minutes-long pass.
The first implementation mapped queue boundaries to `0%` and `100%`, which left
the live UI claiming `0% complete, source 1 of 1` while the model was using a
full CPU core and progressing normally. That was internal state presented as
user progress.

**Consequence:** The UI is honest about the unavailable estimate. Future real
progress requires model support or a measured processing boundary that does not
damage speaker continuity.

## 2026-08-26: Rebuild system capture after discontinuities

**Decision:** A detected system-track capture gap or default output-route change
rebuilds the Core Audio process tap and resets AEC3. During recording, log
minute-level near, reference and cleaned RMS plus attenuation.

**Why:** After a shared HAL overload, the process tap continued delivering
buffers but its signal fell about 22 dB and no longer correlated with speaker
output. Transport-only supervision therefore considered a broken reference
healthy for 27 minutes. Switching output routes rebuilt the surrounding Core
Audio graph and restored both the reference and cancellation.

**Consequence:** A short discontinuity costs another short padded gap while the
tap is rebuilt, but cannot silently poison the remainder of a call. The source
writer and timeline survive the rebuild. Health logs distinguish capture
liveness from useful AEC input without putting analysis on the realtime thread.

## 2026-08-26: Choose the source for reversible voice separation

**Decision:** Transcript review presents independent `Separate Remote Voices`
and `Separate Local Voices` actions whenever the corresponding source exists.
The user chooses the source based on the meeting rather than Quill ranking or
combining them. Before the first separation pass,
preserve the canonical baseline transcript in
`.quill/transcript-before-speaker-separation.json` and offer exact undo after
success. State the current four-voice-per-track limit.

**Why:** A 3:42 call contained remote speech around -58 to -62 dBFS in the
cleaned local track. It sounded nearly absent, but Sortformer clustered it as
four local voices. A fixed offline noise gate separated one tested leakage clip
from the loudest local speech only at thresholds that also removed quieter
candidate local speech, so this meeting does not justify a universal gate or a
modal warning. Processing Local and Remote also doubled the five-minute runtime
when only remote identity was wanted. Meetings with more than four remote people
exceed Sortformer's representational limit. Speaker separation is optional
analysis, so a bad result must not irreversibly replace the useful coarse
transcript.

**Consequence:** Separating either source retains the other source's coarse
identity, avoids unnecessary processing, and prevents contamination on one
track from affecting diarisation of the other. The review window reports model
preparation, current source, source count and coarse percentage; the model API
does not expose within-file progress. The snapshot is written once and removed
only after a successful restore. Sessions separated before this decision have
no exact snapshot and must rerun ASR to recover their baseline.

## 2026-08-26: Split clock fits at repaired capture gaps

**Decision:** Number uninterrupted capture segments within each track and route
epoch. Persist that segment number with every clock observation and fit each
segment independently. Continue measuring without correcting audio drift.

**Why:** A whole-epoch regression across a shared padded gap reported +207 ppm
for one microphone epoch and distorted the final relative summary. Contiguous
sections of the same long meeting measured roughly +0.8 to +3.0 ppm with maximum
residuals around 14 ms. Inserted silence describes timeline repair, not device
oscillator rate.

**Consequence:** Future summaries cannot count padded gaps as clock-rate error.
The strongest comparable section in this meeting implied roughly 28 ms over
9,338 seconds, which does not justify resampling or a new alignment model.

## 2026-08-25: Measure capture clocks before correcting drift

**Decision:** Persist sparse callback-clock observations for each source and
route epoch in `.quill/clock-observations.jsonl`. Record the device sample
position, Core Audio host time and normalized output frame every minute, then
summarize fitted device rate, normalized rate, residual timing error and
relative microphone-to-system drift in `session.log`. Do not correct the audio
timeline yet.

**Why:** Initial alignment cannot reveal long-term drift, and final file lengths
conflate oscillator error with startup offset, callback jitter, resampling,
route changes and inserted silence. Both capture APIs already supply timestamps
in the common Core Audio host-time domain. Measuring those timestamps during a
long real meeting can establish whether correction is necessary and what model
the evidence supports.

**Consequence:** Clock observations are non-authoritative diagnostics and never
block source capture. They are sampled and written only after the corresponding
source frame reaches the archive writer queue, not from the realtime callback.
A future clock reconciler must be justified against these observations and
preserve route changes as separate timing epochs.

## 2026-08-24: Normalize terminal and non-terminal Swift builds

**Decision:** Shared builds run through `build.sh`, which selects Apple Swift
with `xcrun` and passes `--no-color-diagnostics`. Release tests pass the same
diagnostic setting explicitly.

**Why:** SwiftPM selected colored diagnostics in Terminal and non-colored
diagnostics for agent processes, then treated that presentation difference as
a changed compiler invocation and repeatedly rebuilt FluidAudio. Forcing color
did not work without a TTY. Forcing non-color reused the same isolated probe
cache across non-terminal and PTY builds.

**Consequence:** Humans, agents and CI share `.build` without changing compiler
fingerprints according to their output device. Direct `swift build` is not a
supported project command.

## 2026-08-24: Compile optimized Quill sources in parallel

**Decision:** The Quill executable disables whole-module optimization in
release builds while retaining `-O`. Dependency products keep their own release
settings.

**Why:** SwiftPM's default release configuration compiled the entire executable
in one compiler process after a source edit. It took 77.79 seconds despite ten
configured jobs. Without whole-module optimization, the same complete Quill
compile took 12.55 seconds, and a subsequent source edit took 9.69 seconds.

**Consequence:** Quill gives up cross-file optimization within its orchestration
executable. FluidAudio, WebRTC and other dependency products retain their
production build settings, and the Quill compile can use the configured job
parallelism. Release-configured tests use a separate scratch directory so their
`-enable-testing` modules cannot invalidate the production release cache.

## 2026-08-24: Use the Apple Command Line Tools Swift compiler

**Decision:** Local and release builds use the Swift compiler selected by
`xcrun` from the active Apple Command Line Tools installation. Quill does not
carry a Swiftly version pin. CI may still supply an explicit `SWIFT` executable.

**Why:** Swiftly and Apple Swift provided two compiler identities writing to the
same SwiftPM build directory. Switching from Swiftly 6.3.2 to Apple Swift 6.3.3
invalidated every target and caused a 96.78-second rebuild. The installed Apple
Swift 6.3.3 compiler builds and runs against the installed macOS 26.5 SDK in an
unrestricted cold probe. A restricted probe instead failed when the sandbox
blocked module-cache writes, so that failure was not evidence that a second
compiler was required.

**Consequence:** Updating Command Line Tools may require one clean recompilation;
ordinary builds no longer switch toolchains according to shell startup
behavior. The test target pins the official Swift Testing source release because
CLT's bundled framework failed both module import and test discovery. That
dependency is test-only and is not linked into Quill.

## 2026-08-24: Keep complete keyboard access and add a fast naming path

**Decision:** Transcript review gives initial focus to the first speaker name.
Tab follows the visible control order, including each sample button. Return in a
name advances directly to the next name, and Return in the final name saves.
Content refreshes restore the focused control when it still exists.

**Why:** Removing sample buttons from the Tab loop would make rapid name entry
faster by making a keyboard-only action unreachable. A separate Return path
keeps every control navigable while making repeated naming efficient.

**Consequence:** Focus order is explicit and tested rather than derived from
AppKit view hierarchy. Accessibility help announces the Return behavior, and
Settings controls expose purpose-specific labels rather than relying on nearby
visual text. Quill installs standard application, File, Edit and Window menus;
text commands route through the first responder while Quit retains Quill's safe
recording shutdown.

## 2026-08-24: Publish a DMG and updater ZIP for every release

**Decision:** Every beta and stable GitHub Release contains a signed, notarized
DMG for first installation and a ZIP for Sparkle. Both are built from the same
version-stamped app. The appcast references only the ZIP.

**Why:** A DMG provides the conventional drag-to-Applications installation,
while ZIP is the simpler invisible updater transport. Omitting the DMG from
betas prevents a new tester from joining the beta channel without a separate
local build.

**Consequence:** The release receipt binds both artifacts by hash, publication
uploads and downloads both for verification, and either channel can be
installed directly from its GitHub Release page.

## 2026-08-24: Publish signed updates from one resumable release script

**Decision:** Quill uses Sparkle's standard updater with periodic checks and a
manual menu action. Source versions name the exact `X.Y.Z-dev` release train;
release tags select stable or `beta.N` artifacts. Trunk builds use the
first-parent commit count. A `release/X.Y` maintenance branch derives dotted
builds from the latest stable item in the published appcast: stable build `80`
is followed by maintenance builds `80.1`, `80.2` and so on. One `release.sh`
checks, builds and publishes locally now and remains the implementation called
by a future tag-triggered GitHub Actions workflow.

**Why:** Appcast order is not update order, and separate local and CI release
implementations would drift across versioning, signing and publication. A
receipt lets the external publish step prove it is exposing the exact archive
that passed tests, notarization and Sparkle signing.

**Consequence:** GitHub Releases hold immutable ZIPs and GitHub Pages holds one
stable HTTPS appcast. Beta items share that feed through Sparkle's channel
mechanism. Maintenance branches must match their release line, descend from its
latest stable tag and match their pushed remote. Their dotted builds update
stable clients without replacing a newer trunk beta. Maintenance publication
activates the appcast through a separate `master` worktree. The appcast remains
the last publication boundary. Update installation can never relaunch Quill
while a recording or its stop drain is active.

## 2026-08-24: Make stop an asynchronous lifecycle boundary

**Decision:** Stop detaches both realtime capture graphs on the main actor, then
suspends while source archives close concurrently. Accepted-frame delivery,
live AEC finishing and manifest IO also run off the main actor. Duplicate stop
requests share the one in-progress stop task, and shutdown waits for it before
terminating.

**Why:** `RecordingSession.stop()` synchronously drained source and live queues
on the main actor. Normal stops were quick, but a near-limit backlog could freeze
the menu and companion at the exact moment the user requested feedback.

**Consequence:** The interface enters `Finishing audio` immediately and remains
responsive while the same close, failure reconciliation and publication order
completes. A blocked-writer regression test proves archive draining suspends
rather than blocks the main actor.

## 2026-08-24: Give offline audio preparation one owner

**Decision:** `AudioPreparation` resolves safe source paths, validates cleaned
microphone audio, runs offline AEC when needed and returns one prepared input
set. Finalization, baseline transcription and speaker separation consume that
same result. Cleanup failure returns the raw microphone rather than failing a
usable transcript.

**Why:** `AudioFinalizer` and `TranscriptionCoordinator` independently selected
cleaned inputs and invoked AEC. Their policies could drift, while transcription
still needed graceful degradation when publication failed.

**Consequence:** `EchoCancellation.clean()` has one production caller and
transcription no longer owns audio cleanup policy. Invalid disposable internal
derivatives may be rebuilt; invalid human-facing audio is preserved as evidence.
Best-effort raw transcription remains the explicit failure behavior.

## 2026-08-24: Give persisted session state one typed owner

**Decision:** `SessionManifest.swift` owns the Codable schema and atomic IO for
`capture.json` and `meta.json`. Capture, recovery, finalization, transcription,
processability checks and diagnostic replay use the same typed files, offsets,
track health and audio-state definitions.

**Why:** Raw JSON dictionaries spread legal states and default behavior across
four production owners. A typo or a new state could compile and then be
interpreted differently by recovery and transcription.

**Consequence:** Existing JSON remains compatible and missing legacy optional
fields keep their previous defaults. An unknown future `audio_state` fails
decoding instead of being silently rewritten by older code. The session folder
remains the persistence unit; one small document does not justify a database or
a migration framework.

## 2026-08-24: Isolate optional live consumers from source archival

**Decision:** After a source encoder accepts a normalized frame, `TrackWriter`
creates one immutable `AcceptedFrame` and offers it to an immutable fan-out.
Each consumer owns a bounded mailbox and runs on its own queue. The AEC mailbox
holds at most 30 seconds of accepted PCM; overflow abandons live AEC and mixing.

**Why:** Independent review confirmed that the synchronous AEC monitor could
wait for the processor lock while holding the source writer lock. That allowed
optional processing to delay later archive writes and eventually contribute to
source queue overflow.

**Consequence:** Consumer work and consumer locks no longer run on source
archive queues. A stalled-consumer regression test closes a complete source
file while its AEC-like consumer remains blocked. Source encoder acceptance
still precedes fan-out, and offline processing remains the recovery path for an
abandoned live consumer.

## 2026-08-24: Preserve the surviving source after an archive failure

**Decision:** The first AAC write failure permanently closes that source track,
leaves its existing bytes for recovery, marks recording degraded and interrupts
immediately. The other source continues. Live AEC and mixing are abandoned. If
both source archives fail, Quill stops the session automatically.

**Why:** Continuing to report healthy recording when device callbacks arrive
but no bytes reach the source file is false confidence. Retrying the same AAC
writer has no established recovery contract, while stopping both tracks for one
failure discards a useful surviving source.

**Consequence:** A partial failed track remains publishable when it contains
audio; an empty track is omitted from finished metadata. Retry and segmented
source files remain out of scope until a real incident justifies them.

## 2026-08-24: Consumer isolation requires an explicit archive contract

**Decision:** Correct the earlier committed-frame direction: the current
monitor is ordered after source encoder acceptance, but still runs synchronously
on the archive queue. The target boundary must enqueue consumer work in bounded,
constant time without executing consumer code there. Each stateful consumer must
define what a missing frame does to its own state.

**Why:** Independent review found that a slow monitor can delay later archive
writes until the capture queue overflows. It also found that `AVAudioFile.write`
is an encoder-acceptance boundary, not proof that bytes reached stable storage.
The earlier wording promoted intended isolation and durability into guarantees
the current implementation does not provide.

**Consequence:** Keep source acceptance before optional fan-out, but call it
process-crash recoverability rather than immediate durability. Before adding a
new live consumer, remove consumer execution from the archive queue and choose
an overload outcome appropriate to that consumer.

## 2026-08-24: Keep capture open to future live consumers

**Decision:** Live transcription is not current scope, but audio capture must not
assume that files are its only consumers. Preserve one normalized, timestamped
frame boundary after source encoder acceptance. Live AEC and metering, plus
future ASR, may consume that boundary without changing microphone capture,
system capture or source-file recovery.

**Correction:** The following consumer-isolation decision supersedes this
entry's original use of “durable source writes.” Encoder acceptance does not
prove power-loss durability or successful finalization after an IO error.

**Why:** The current source-first recovery model is sound, but `TrackWriter`
combines normalization, timeline reconstruction, persistence and fan-out. Adding
live ASR directly to that type would deepen the coupling and give each consumer
its own timing and backpressure rules.

**Consequence:** Do not build live ASR or a general audio graph speculatively.
When adjacent audio work next changes this boundary, separate canonical frame
production from persistence and bounded consumer delivery while retaining the
rule that optional consumers cannot delay or endanger the source archive.

## 2026-08-20: Make recording confidence converge on one pill

**Decision:** Active recording uses the same red `circle.fill` symbol in the
menu bar, expanded companion and collapsed pill. Expanded recording uses a
right chevron to collapse toward its anchored edge; `X` is reserved for actual
dismissal. Pointer hover extends expanded controls to eight seconds but cannot
hold them open indefinitely.

**Why:** Different SF Symbol configurations made one nominal recording glyph
look like a donut and another like a solid dot. `X` also promised closure when
recording actually remained visible. Indefinite hover made a manual menu start
look as if automatic pillification had failed when the panel appeared beneath
the pointer.

**Consequence:** Manual and detected recordings share the same collapse rules.
Deliberate interaction buys enough time to use Stop without turning incidental
pointer position into persistent window state.

## 2026-08-20: Give transcript review normal app presence

**Decision:** Quill remains one application and one process. It normally uses
the accessory activation policy. Opening transcript review temporarily switches
to the regular policy so Quill appears in the Dock and Command-Tab switcher;
closing review restores the accessory policy.

**Why:** The menu-bar companion is transient utility UI, but transcript review
is a focused task window that people need to leave and return to like any other
Mac window. Excluding it from Command-Tab makes an open window unnecessarily
hard to recover.

**Consequence:** `LSUIElement` remains the launch default. No helper application
or second bundle is introduced, and Quill has no permanent Dock presence.

## 2026-08-20: Show meeting context, not capture plumbing

**Decision:** The expanded recording companion uses the detected application as
its subtitle. Manual recordings have no subtitle. Normal recording does not
display `microphone and computer audio`; a capture failure may use that space
for an actionable exception.

**Why:** The companion provides recording confidence and immediate control.
Repeating the internal capture sources adds visual weight without helping that
task, while the meeting application identifies which session the timer belongs
to.

**Consequence:** Source detail remains available through permissions,
documentation and the retained `Local` and `Remote` files, not as persistent
recording chrome.

## 2026-08-20: Keep companion placement session-scoped

**Decision:** Every new recording session places the meeting companion at its
default top-right position near system notifications. Dragging moves it for the
remainder of that session only. All state changes, including expansion and
collapse, retain the dragged position and preserve the right edge.

**Why:** A drag is normally a response to the layout of the current call. Making
that position permanent causes a later prompt to appear wherever the previous
meeting happened to need it, rather than where notification-like UI is expected.

**Consequence:** Detection and a manual start from idle reset placement. Starting
a detected recording does not, because detection and recording are one session.
Display changes still clamp the companion on-screen.

## 2026-08-20: Separate voice identity from source context

**Decision:** Before individual speaker separation, microphone speech is
labelled `Me` and system-audio speech is labelled `Them`. Both coarse groups
can be sampled and named directly. `Separate Voices` is optional. After
separation, unnamed voices become globally numbered `Voice 1`, `Voice 2` and so
on. The native review shows `local` or `remote` as quiet secondary context;
source context does not enter Markdown after separation. The transcript review
has standard macOS window controls and a footer with file actions, `Close` and
`Save Names`.

**Why:** Coarse labels describe groups, while voice labels describe fallible
identity clusters. `Me` and `Them` make the common one-to-one transcript
immediately legible and nameable without running another model. Keeping source
context separate after analysis makes a false split visible, such as two local
voices when only one person used the microphone, without forcing source
terminology into speaker names. An explicit Close action makes the task
window's exit discoverable without removing standard window chrome.
The retained source files use the same neutral source vocabulary:
`Source Audio/Local.m4a`, `Local Cleaned.m4a` and `Remote.m4a`.

**Consequence:** Voice numbers are unique across both source tracks. A coarse
group name carries through separation only when that source produces exactly
one voice; a split source remains unnamed. Unsaved names are saved before
separation. Naming two voices identically gives them one readable transcript
label without rewriting the underlying clusters. Closing with unsaved names
offers Save, Don't Save and Cancel. Old transcripts are not rewritten.

## 2026-08-20: Complete transcription in one review flow

**Decision:** `Saving recording…` and `Creating transcript…` remain in the
meeting companion until work completes or the person dismisses it. Completion
becomes `Transcript ready` with a `Review` action. That action and the native
completion notification open the same read-only Quill transcript window. The
transcript is primary; optional speaker separation, sample playback and naming
sit beside it. `Open Transcript File` exposes the editable and portable
Markdown artifact.

**Why:** A timer-based handoff could remove useful progress while someone was
waiting for it. Opening Markdown at completion also split the review job from
the only surface capable of speaker analysis and audio playback. The person has
just entered transcript-review mode, so this is the right moment to expose that
optional work without complicating recording.

**Consequence:** Dismissing progress never cancels processing. It changes only
the completion surface from the companion to a native notification. The review
window does not edit transcript prose. Collapse and expansion preserve the
companion's right edge so its initial top-right placement remains stable.
Engine and diarizer provenance remains in `.quill/transcript.json`; the
human-facing Markdown contains only its title and transcript.

## 2026-08-20: Separate speakers only during transcript review

*Speaker labels in this decision were superseded by "Separate voice identity
from source context" above. Analysing both tracks without asking was superseded
by "Choose the source for reversible voice separation" above.*

**Decision:** Every completed recording produces a baseline transcript with
`In the room` and `On the call` labels. Recording has no meeting profile,
diarisation control or transcription switch. `Review Last Transcript…`
optionally analyses both retained source tracks, reassigns the
existing timed transcript segments, then lets the user name speakers from
short samples.

**Why:** Recording, transcription and speaker separation are different user
jobs. Asking about meeting shape during capture exposed a processing parameter
at the most time-sensitive moment. After reading the baseline transcript, the
user can judge whether individual speaker labels are worth the wait.

**Consequence:** Speaker separation never reruns speech recognition and never
changes words. It atomically replaces speaker metadata and Markdown only after
analysis succeeds; failure preserves the baseline. Both tracks are analysed,
so the UI never asks where multiple people were. Automatic separation remains
out of Settings until the manual workflow proves useful.

## 2026-08-20: Close recording controls, not recording confidence

**Decision:** During recording, X and Escape collapse expanded controls back to
the activity pill. The pill is one click-or-drag target: clicking anywhere
expands it and dragging anywhere moves it. Other companion phases retain X as
dismiss. Initial placement is at the top right near the system notification
area; an explicit drag still wins over automatic placement. Recording collapses
to the pill three seconds after capture starts; an explicit reopen lasts eight
seconds.

**Why:** A close glyph on controls reads as closing those controls, not as
removing the recording indicator for the rest of the session. Splitting the
small pill into separate drag and action regions also makes the most persistent
surface unnecessarily difficult to move.

**Consequence:** Recording capture confidence remains visible until Stop.
Expanded controls are temporary detail over that persistent pill. Possible-end
X explicitly acknowledges Keep Recording and collapses. Live voice settings
state where multiple people are present, so the control describes the meeting
shape rather than repeating that a transcript will be produced.

## 2026-08-19: Keep finished session folders human-facing

**Decision:** A finished session root contains only `Meeting Audio.m4a`,
`Source Audio/` and `transcript.md`. Capture files, metadata, canonical
transcript JSON and per-session logs live together under `.quill/`. M4A staging
also happens there. New code uses this layout directly and does not migrate old
session folders.

**Why:** A recording folder is a user artifact, not an application data dump.
The technical files are necessary for recovery, diagnostics and future
reprocessing, but exposing them beside the files a person opens makes the
finished result look incomplete. One internal directory keeps their lifecycle
coherent without introducing a database or a migration layer.

**Consequence:** `.quill/` is the single owner of capture journals, CAF working
files, `meta.json`, `session.log`, `transcribe.log`, `transcript.json` and export
partials. Verified M4A files move to their visible destinations before metadata
is published, then CAF working files are deleted. Old schemas and layouts are
ignored safely rather than upgraded.

## 2026-08-19: Let each companion state earn its size

**Decision:** The detected and action states use a 380 × 72-point companion.
Detected expires after 12 seconds with a draining deadline bar. Recording keeps
the expanded controls for four seconds, then becomes a 48 × 72-point activity
capsule. The capsule reopens controls for eight seconds; possible end expands
automatically. A dragged position is preserved through state changes and timer
updates.

**Why:** A persistent prompt-sized recording surface competes with the meeting
it is meant to support. Removing it entirely would hide Stop and per-recording
voice correction because Quill has no live notes window to own those actions.
The small capsule provides capture confidence and a route back without making
the full workflow permanent.

**Consequence:** Voice status appears only in expanded recording and uses
action language: `Separate voices on the call`, `Separate voices in the room`,
or `Separate all voices`. The deadline bar is the sole animation justified by
an expiring decision. Elapsed-time rendering must never reposition the panel.

## 2026-08-19: Reveal voice controls only after opt-in

**Decision:** The detected-meeting companion contains only the application and
`Record`. During recording, the companion shows a quiet `Voices` control only
when separation was already active or was changed in that session. The menu and
companion edit one per-recording value. A live change never changes the saved
default. Turning separation Off keeps the control visible until that recording
ends.

**Why:** The common one-to-one case should not introduce diarization or a setup
question. Someone who opted into voice separation still needs confidence that
the choice is active and a nearby way to correct it. Hiding the control
immediately after selecting Off would make that correction hard to reverse.

**Consequence:** The companion does not ask about meeting structure before
capture. The menu remains the persistent default and the fallback when live
controls are dismissed. Post-stop changes require future transcript
reprocessing while source audio still exists.

## 2026-08-19: Keep voice separation out of the recording flow

**Decision:** Voice separation defaults to `Off`, including detected calls. The
meeting companion never asks about it. The menu offers the optional `Separate
Voices` choices `Off`, `On the call`, `In the room` and `Both`. An idle choice
persists as the default; a live change affects only that recording.

**Why:** Detecting a calling app says where audio comes from, not how many people
are speaking. Automatically diarizing every call adds a model download, extra
processing and the risk of splitting one person into several labels. Asking a
meeting-structure question before recording makes a time-critical action feel
procedural. The simple path should remain `Record` and `Stop`.

**Consequence:** This supersedes the detected-call default and companion profile
control in the earlier meeting-companion decision. The per-recording profile
remains in metadata so people who opt in get reproducible processing and can
later request voice separation from a completed recording with retained source
audio.

## 2026-08-19: Finish recordings as M4A while capturing into CAF

**Decision:** Continue writing AAC into CAF while a recording is active. After
a clean stop, produce `Meeting Audio.m4a` at the session root and place the
separate `Local.m4a` and `Remote.m4a` tracks under `Source Audio/`. Keep the
CAF inputs until every replacement has been opened and its duration verified.
Recover and finalize surviving CAF files after a crash. Do not offer WAV export.

**Why:** CAF protects audio already written if Quill or the Mac stops during a
meeting, but it is an unfamiliar finished format. M4A is easy to play and share,
and matches the AAC payload Quill already records. Converting existing AAC to
WAV would increase size without restoring information lost during encoding.

**Consequence:** CAF is working state, not the finished user-facing archive.
`.quill/meta.json` owns file paths, and transcription, retention and recovery must not
hard-code extensions. The combined meeting file uses the cleaned microphone
and call tracks; separate source tracks remain available for verification,
voice samples and future reprocessing. Packet-preserving CAF-to-M4A conversion
with Apple media APIs is verified before source CAFs are removed. Quill records
a small capture journal before opening the audio taps, validates every finished
file with a complete decode, and publishes updated metadata before deleting CAF
working files. Quill does not migrate older session layouts.

## 2026-08-19: Voice review is identification, not transcript editing

**Decision:** `Identify Voices…` assigns human names to stable machine voice
IDs in transcript schema v1. For each voice, it offers a short source-audio
sample and up to two alternatives. Saving renames one voice cluster everywhere;
it does not reassign individual sentences, merge clusters or become a general
transcript editor.

**Why:** `Remote voice 1` is only useful if a person can identify it. Timed
diarization already provides candidate regions, and a representative clip is
faster to recognize than hunting through a transcript. Markdown can display a
finished transcript but cannot safely maintain identity mappings or play the
right source interval.

**Consequence:** Machine IDs and human labels are separate data owned by the
canonical `transcript.json`; no label sidecar or database is introduced. Label
updates rewrite that document and its Markdown rendering atomically. Samples
are ranked by useful duration and recognized words and play directly from the
retained source track. Existing names remain editable when retention removes
that track; only playback becomes unavailable. Playback is also unavailable
during recording. Incompatible transcript JSON is ignored; no migration path
is maintained. Markdown remains
the reading and export format; the Quill review surface exists only for actions
a static document cannot do.

## 2026-08-19: One meeting companion spans the live workflow

**Decision:** The planned custom surface is a meeting companion, not a custom
replacement for every macOS notification. It moves from detected meeting, to
recording, to possible end, to short post-processing and, when fast enough, to
transcript ready. It is non-activating, dismissible and secondary to the menu
bar's canonical state. Native notifications remain the fallback for failures
and asynchronous completion after the companion has gone.

Detected calling apps default to the `On the call` profile. Recording starts
immediately when `Record` is pressed; choosing a profile never blocks capture.
The four user-facing profiles under `Multiple People` are `Neither`, `On the
call`, `In the room` and `Both`.
Quill always captures both tracks, snapshots the chosen processing profile in
the recording metadata, and allows correction while recording. An idle menu
change updates the manual-recording default; a live correction affects only the
current session.

**Why:** A custom banner alone would duplicate macOS while taking ownership of
window levels, Spaces, displays, focus, accessibility and dismissal. A single
surface earns that cost by preserving context and controls throughout the live
meeting. Asking where multiple people are avoids the jargon and ambiguity of
`Hybrid` and `diarization`, while `Neither` preserves one-to-one calls without
unnecessary voice separation.

**Consequence:** The companion remains visible through stopping and brief
transcription. It can become `Transcript ready` with an `Open` action if that
happens while visible. After ten seconds, or when dismissed, processing returns
to the menu and eventual completion uses a native notification. An end signal
changes the same surface to `Meeting ended?`; recovery returns it to the timer.
The implementation must verify non-activation, full-screen Spaces, multiple
displays, VoiceOver and a non-irritating placement before replacing the native
start and stop prompts.

Recordings made before profiles exist retain the current per-track processing
behaviour. They are not rewritten in place merely to acquire a profile.

## 2026-08-19: Keep call prompts compact and recoverable

**Decision:** Start prompts read `Meeting detected` / app / `Record`; end
prompts read `Meeting ended?` / app / `Stop`. Both request banner and
Notification Center list presentation. A recovered call removes its end prompt
and invalidates that action.

**Why:** A larger meeting overlay covered Quill's short-lived banner during
live testing. The action disappeared before it could be used, and the extra
sentence repeated information already carried by the app name and button.

**Consequence:** The banner can remain brief without losing the action. Stale
end prompts cannot stop a recording after its bound application recovers.

## 2026-08-19: Label the shared WebKit audio helper as Safari

**Decision:** Normalize `com.apple.WebKit.GPU` to Safari for call detection.

**Why:** A live Google Meet in Safari placed microphone IO on that helper, not
`com.apple.Safari`. The helper is launched directly by `launchd`, and public
process parentage does not attribute it to Safari or a specific Safari web app.
The chosen product label favors browser-call coverage over preserving that
implementation ambiguity.

**Consequence:** Safari meetings can prompt. A Safari web app, or another app
whose microphone IO uses the shared WebKit GPU helper, may also be labeled
Safari.

## 2026-08-19: Call prompts belong to the menu app

**Decision:** The menu app continuously observes audio-input processes and owns
all call prompts. A recognized application must remain active for two seconds
before Quill offers to record. Only accepting that action binds the recording
to the application; two seconds of absence then offers to stop. Both actions
remain explicit. `quill watch-calls` exercises the same scanner and reducer but
only prints diagnostics.

**Why:** Live checks detected Voice Memos as unknown, normalized Zen Browser,
and produced stable start and end transitions without a real call. They also
showed noisy helper activity from CoreSpeech and duplicate banners when two
diagnostic observers were allowed to notify. Audio-input activity is useful
evidence of a possible call, not proof of one.

**Consequence:** Unknown processes can appear in the disposable detection log
but cannot prompt. The menu app is the only process allowed to turn transitions
into notifications or recording actions. Automatic start and stop remain out
of scope until application-specific false transitions have been measured.

## 2026-08-19: The installed app bundle is the only executable copy

**Decision:** Install Quill at `~/Applications/Quill.app`. The `quill` command
is a symlink to the executable inside that bundle. Every install quits the
running app, replaces the bundle and relaunches it.

**Why:** A separately copied binary in `~/.local/bin` remained on an older
build than the app, so the same command name exposed different features from
the running product.

**Consequence:** `./install.sh` is the live installation command. Installing is
an intentional restart, and rollback restores both the bundle and CLI link if
the replacement does not launch.

## 2026-08-17: Cancel speaker playback after capture

**Decision:** Capture raw microphone and system audio, then use the system track
as WebRTC AEC3's reference to produce a retained `mic-cleaned.caf`. Transcribe
the cleaned microphone track and raw system track. Fall back to raw microphone
audio if cancellation fails.

**Why:** The microphone physically records clear laptop-speaker playback, so the
same remote speech is transcribed from both tracks. Apple's live voice-processing
unit removes it but ducks the captured system track by about 8 dB and has
produced silent or slow-starting microphone graphs. Offline AEC3 removed the
duplicate speech in the recorded fixture without changing capture.

**Consequence:** Raw CAFs remain authoritative and unchanged. The cleaned track
is published by atomic rename, survives with the transcript under raw-audio
retention policies, and can be regenerated while both raw tracks exist. The old
`Cancel Echo from Speakers` control and `mic_voice_processing` behaviour are
removed; an existing config key is harmless and ignored.

## 2026-08-11: One transcription toggle, in the menu

**Decision:** `Transcribe After Recording` lives in the operational menu only.
Settings reports the transcription engine and manages its models but does not
repeat the toggle.

**Why:** The duplicated Settings label, `Transcribe recordings automatically`,
immediately read as a second behaviour, possibly live transcription. Both
controls wrote the same persistent value. The exception was justified from the
information architecture without testing the resulting language as one product.

**Consequence:** Persistent does not mean Settings-owned. A control belongs
where the decision is made; this one is made before a recording.

## 2026-08-11: Separate operation from administration

**Decision:** The menu operates Quill: status, recording actions, immediate
recovery and choices made from meeting context. Settings administers Quill:
launch behaviour, storage policy and downloaded resources. Duplication requires
an operational reason rather than membership in two plausible groups.

**Why:** The previous split exposed durable launch behaviour in the operational
menu, duplicated echo cancellation without adding capability, and presented a
disabled one-option engine picker. It mixed frequency, persistence and subsystem
ownership until neither surface had a coherent job.

**Consequence:** Open at login lives in Settings; echo cancellation lives in the
menu; transcription remains the one shared default; folder changing appears in
the menu only as access recovery; Parakeet is static information until another
engine actually ships.

## 2026-08-10: Keep source audio unless the user chooses deletion

**Decision:** Keep both CAF tracks indefinitely by default. Settings offers
30-day retention and deletion immediately after a successful transcript.

**Why:** A transcript is derived data. The audio is required to verify a quote,
correct recognition errors, or transcribe again with a better engine. Silent
automatic deletion would be an irreversible surprise.

**Consequence:** Only sessions containing `transcript.json` are eligible for
cleanup. Changing to a destructive policy requires confirmation, and cleanup
waits for `on_stop` to finish.

## 2026-08-10: Keep level-based silence detection

**Decision:** Keep the current RMS-based ten-minute nudge. Do not add a
level-variation heuristic or Silero VAD yet.

**Why:** Variation rejects steady fans but still accepts music and keyboards,
while introducing false notifications during quiet speech. Silero makes a more
honest voice claim but adds another model and continuous inference for a
low-cost failure.

**Consequence:** Background noise can suppress the nudge. If real recordings
show that this matters, measure representative noise and speech before changing
the signal.

## 2026-08-10: One macOS application home and one config file

**Decision:** Store all configuration in
`~/Library/Application Support/Quill/config.json`. The menu, Settings and
hand-edited keys share that file.

**Why:** The old config/state precedence silently ignored hand edits and split
one application's persistent state across two files.

**Consequence:** UI writes preserve unknown keys but may normalize JSON layout.
`QUILL_HOME` provides an isolated development and test home.

## 2026-08-10: Enable launch at login only for a fresh install

**Decision:** A first bundled launch registers Quill with `SMAppService`.
Upgrades retain the system's existing choice.

**Why:** A menu-bar recorder that is absent when a meeting starts has already
failed, but an upgrade must not reverse a deliberate opt-out.

**Consequence:** The initialization marker lives in the unified config file.

## 2026-08-24: Capture the system tap as mono

**Decision:** Pin the system track's file format to 1ch 48 kHz and average the
tap's channels into it, rather than writing the tap's stereo format raw.

**Why:** Every consumer already discarded the second channel. Echo cancellation
averages the far end to a mono reference, ASR and diarization are mono, and
`mix()` sums both tracks with no panning, so the published stereo carried
duplicated speech at twice the size and twice the live encode cost.

**Consequence:** The downmix is explicit in `TrackWriter`, because
`AVAudioConverter` answers a 2ch to 1ch request with the left channel alone and
would have silently dropped a right-panned participant. Single-channel content
now lands at half amplitude, which is ordinary downmix behaviour. Sessions
recorded before this keep their stereo system track; nothing reads the channel
count.

## 2026-08-24: Cancel echo live, keeping the offline pass as fallback

**Decision:** Run AEC3 during the meeting from a `TrackMonitor` on both
`TrackWriter`s, publishing `mic-cleaned.caf` only on a clean finish.
`EchoCancellation.clean()` stays exactly as it was and runs when that file is
absent.

**Why:** Echo cancellation was ~70s of the ~126s a 53 minute meeting spent after
stop, shown as an indeterminate spinner. AEC3 is a streaming block algorithm, so
live is its native mode and costs about 2% of a core spread across the meeting.

**Consequence:** Alignment moves from the journal's `start_offset_ms` to the
live path, because the bridge reports zero buffer delay and so trusts the caller
to sample-align near and far. The monitor fires inside `TrackWriter`'s write
lock and must only copy. Live never blocks capture: it abandons and leaves the
work to the offline pass rather than applying backpressure. The two paths are
not sample-identical, because offline reads the tracks back through AAC while
live sees them before the encode; measured on `check-live-aec`, live holds
14-16 dB ERLE across track skews of 0-250ms where a deliberately corrupted
offset drops it to 6 dB.

## 2026-08-24: Build the mono meeting mix during capture

**Decision:** The live echo-cancellation pump also writes an aligned mono AAC
meeting mix at 64 kbps. On clean stop, finalization verifies and remuxes that
CAF into `Meeting Audio.m4a`. If live processing is absent or incomplete, a
streaming offline mixer rebuilds the same mono artifact from retained tracks.

**Why:** Source tracks already encode during capture and publish by passthrough
remux. The remaining normal-path audio cost was decoding both complete tracks
and encoding a 2-channel 248 kbps meeting file after stop, even though every
consumer treats the call as mono. The AEC pump already holds the aligned cleaned
microphone and far-end samples needed for that mix.

**Consequence:** A normal stop closes completed AAC files and performs only
validated container remuxes before transcription. The live mix includes
far-end audio before the microphone starts and after it ends. Recovery retains
the full offline path. A 58-second real-session replay produced the same
2,786,928-frame duration at 65 kbps and 504 KB, compared with the former
2-channel file at 251 kbps and 1.84 MB. A 15-minute replay sustained 20 times
realtime input and finalized in 1.16 seconds.

## 2026-08-24: Generate AEC alignment fixtures from one clock

**Decision:** Synthetic near and far signals are generated against one global
sample timeline, then sliced according to each track's start offset. The
deliberate misalignment remains a separate input to the canceller.

**Why:** The first fixture shifted the far signal in the same direction as its
start offset. That made the supposedly aligned tracks inconsistent, while
AEC3's internal delay estimator partially hid the error. It could distinguish
zero skew from a corrupted offset but could not prove the caller's offset math.

**Consequence:** Corrected controls retain 13-16 dB ERLE when either track leads
by 250 ms, preserve the exact meeting duration, and drop to 6.3 dB when the
offset is deliberately corrupted by 200 ms. Real-session replay results are
unchanged.

## 2026-08-24: Use one persisted millisecond clock contract

**Decision:** `SessionTimeline` rounds each source's first-buffer lag to the
nearest millisecond once. The capture journal, session manifest, live and
offline AEC, meeting mixing and transcript merging all use that value. Accepted
frames also identify captured samples and silence inserted by `TrackWriter`.

**Why:** Live AEC previously converted the full-precision `Date` difference
directly to samples while every recoverable and offline path truncated it to
milliseconds. The two paths could therefore disagree about alignment for the
same session, and a future live consumer could not distinguish recorded input
from gap repair.

**Consequence:** One millisecond, 48 frames at the fixed 48 kHz rate, is the
declared alignment resolution. The existing limitations remain explicit:
buffer arrival uses non-monotonic wall time, overlapping frames are not trimmed,
and independent device-clock drift is not corrected. A host-time or drift model
requires measured need rather than being introduced for hypothetical live ASR.
