# Decision log

Dated product and architecture decisions. Newest first.

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
from source context" above.*

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
