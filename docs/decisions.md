# Decision log

Dated product and architecture decisions. Newest first.

## 2026-08-19: Finish recordings as M4A while capturing into CAF

**Decision:** Continue writing AAC into CAF while a recording is active. After
a clean stop, produce `Meeting Audio.m4a` at the session root and place the
separate `Microphone.m4a` and `Call.m4a` tracks under `Source Audio/`. Keep the
CAF inputs until every replacement has been opened and its duration verified.
Recover and finalize surviving CAF files after a crash. Do not offer WAV export.

**Why:** CAF protects audio already written if Quill or the Mac stops during a
meeting, but it is an unfamiliar finished format. M4A is easy to play and share,
and matches the AAC payload Quill already records. Converting existing AAC to
WAV would increase size without restoring information lost during encoding.

**Consequence:** CAF is working state, not the finished user-facing archive.
`meta.json` owns file paths, and transcription, retention and recovery must not
hard-code extensions. The combined meeting file uses the cleaned microphone
and call tracks; separate source tracks remain available for verification,
voice samples and future reprocessing. An implementation spike must prove
packet-preserving CAF-to-M4A conversion with Apple media APIs before the source
CAFs are removed. Existing completed CAF sessions remain readable and are
finalized lazily per session; there is no bulk migration.

## 2026-08-19: Voice review is identification, not transcript editing

**Decision:** A future transcript review surface may assign human names to
stable machine voice IDs. For each unidentified voice, it offers a short clean
audio sample and two or three alternatives when needed. The first scope renames
one voice cluster everywhere; it does not reassign individual sentences, merge
clusters or become a general transcript editor.

**Why:** `Remote voice 1` is only useful if a person can identify it. Timed
diarization already provides candidate regions, and a representative clip is
faster to recognize than hunting through a transcript. Markdown can display a
finished transcript but cannot safely maintain identity mappings or play the
right source interval.

**Consequence:** Machine IDs and human labels are separate data owned by the
canonical `transcript.json`; no label sidecar or database is introduced. Label
updates rewrite that document and its Markdown rendering atomically. Sample
selection favors one uninterrupted voice, three to eight seconds of audible
speech, little silence or overlap, useful words and strong recognition
confidence where available. Existing transcripts without stable machine IDs
remain readable but require re-transcription before voice identification.
Markdown remains the reading and export format; the Quill review surface exists
only for actions a static document cannot do.

## 2026-08-19: One meeting companion spans the live workflow

**Decision:** The planned custom surface is a meeting companion, not a custom
replacement for every macOS notification. It moves from detected meeting, to
recording, to possible end, to short post-processing and, when fast enough, to
transcript ready. It is non-activating, dismissible and secondary to the menu
bar's canonical state. Native notifications remain the fallback for failures
and asynchronous completion after the companion has gone.

Detected calling apps default to the `On the call` profile. Recording starts
immediately when `Record` is pressed; choosing a profile never blocks capture.
The three user-facing profiles are `On the call`, `In the room` and `Both`.
Quill always captures both tracks, snapshots the chosen processing profile in
the recording metadata, and allows correction while recording.

**Why:** A custom banner alone would duplicate macOS while taking ownership of
window levels, Spaces, displays, focus, accessibility and dismissal. A single
surface earns that cost by preserving context and controls throughout the live
meeting. Physical descriptions of where people are avoid the jargon and
ambiguity of `Hybrid` and `diarization`.

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
