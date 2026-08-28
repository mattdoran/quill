# Quill UX

The design of Quill's menu bar item, menu, Settings window and notifications.
Prescriptive. Where something is not built yet it is marked **Proposed**;
everything else is what ships today.

## 1. Principles

1. **The menu bar reports one thing: whether quill is recording.** Nothing else
   ever changes the icon. Transcription, downloads and queues live in the menu.
2. **Nothing animates without conveying state.** Nothing in the macOS menu bar
   blinks. The detected-meeting deadline bar is the exception because it shows
   when an unanswered prompt will disappear.
3. **State differs in shape before it differs in colour.** Colour alone is one
   state to a colourblind user, in the strip of screen with the least contrast.
4. **Quill interrupts only when acting in the next minute changes the outcome.**
   Anything you would learn later from the transcript, the menu or a log is not
   a notification.
5. **The dropdown runs Quill; Settings configures Quill.** Status, immediate
   actions, recovery and choices made before a recording belong in the menu.
   Launch behaviour, storage policy and downloaded resources belong in Settings.
6. **A setting has one control surface.** A control does not appear in both
   surfaces merely because it fits both sections. The menu may expose a
   contextual recovery command for a Settings-owned value, but never a second
   copy of the setting itself.
7. **One persistent utility window.** Settings is the only persistent window.
   A focused, task-scoped transcript review window is allowed; wizards,
   general editors and persistent recording windows are not.

## 2. Status item

Set once at launch: `statusItem.autosaveName = "com.mattdoran.quill.status"`, so
the item keeps the position the user dragged it to.

| State | Glyph | Tint | Button title | Accessibility title |
|---|---|---|---|---|
| Idle | feather (inline SVG, template) | none | *(empty)* | `Quill, idle` |
| Starting | `record.circle` | none | *(empty)* | `Quill, starting recording` |
| Recording | `circle.fill` | `.systemRed` | ` 12:03` | `Quill, recording, 12 minutes 3 seconds` |
| Degraded | `exclamationmark.triangle.fill` | `.systemOrange` | ` 12:03` | `Quill, capture problem, 12 minutes 3 seconds` |
| Transcribing, not recording | feather | none | *(empty)* | `Quill, idle` |
| Downloading models | feather | none | *(empty)* | `Quill, idle` |

Rules:

- **Degraded means a track is down right now**, not that one was. `isDegraded`
  drives the icon and clears on recovery; the sticky incident record drives the
  menu line.
- **Transcription never touches the icon.** It runs at roughly 20 seconds per
  hour of audio; an icon that changes for 20 seconds is flicker. The first-run
  model download is the tempting exception and is still refused: the bar reports
  recording, the menu reports everything else.
- **Button title only exists while recording.** `m:ss`, becoming `h:mm:ss` past
  an hour. Monospaced digits, so the icon does not jiggle each tick.
- **Starting changes shape, not width.** The menu action returns before audio
  devices attach, so the outline record glyph acknowledges the click at once.
  The clock appears only after capture succeeds.
- Accessibility titles are spelled out for speech, not read off the clock face.

## 3. Menu

Title case on commands, sentence case on status lines. `✓` marks a checkmark,
`⟨disabled⟩` marks a greyed, unclickable item.

Status lines are disabled, and macOS greys disabled items regardless of any
colour set on `attributedTitle` — tried, and it has no effect. Dimmed status
text is also what Apple's own menu bar extras do, so this is left alone rather
than fought with a custom view.

### Idle

```
Quill is idle                                       ⟨disabled⟩
────────────────────────────────────────────
Start Recording
Open Last Transcript
Review Last Transcript…
Review Earlier Transcript…
Open Recordings Folder
────────────────────────────────────────────
Settings…
Check for Updates…
About Quill
Quit Quill                                      ⌘Q
```

`Open Last Transcript` is disabled when no session has a `transcript.md`.
`Review Last Transcript…` is hidden until the newest compatible
transcript exists. It is disabled during recording so sample playback cannot
enter the capture.
`Review Earlier Transcript…` opens a folder picker at the recordings root and
accepts any past Quill session with a compatible completed transcript. It is
disabled during recording for the same sample-playback reason.
`Retry Transcription` and `Download Transcription Models` are hidden unless they
apply, and appear in the status block at the top. `Change Recordings Folder…`
appears below `Open Recordings Folder` only when Quill cannot read that folder.

### Recording

```
Recording — 12:03                                   ⟨disabled⟩
────────────────────────────────────────────
Stop Recording
Open Last Transcript
Review Last Transcript…                                ⟨disabled⟩
Review Earlier Transcript…                            ⟨disabled⟩
Open Recordings Folder
────────────────────────────────────────────
Settings…
Check for Updates…                                  ⟨disabled⟩
About Quill
Stop Recording and Quit                         ⌘Q
```

During audio-device attachment, the status line reads `Starting recording…`
and the command beneath it reads `Starting Recording…` disabled. The menu-bar
glyph changes immediately, but its title stays empty so startup does not widen
and then shrink the status item.

Update checks are disabled while recording starts or runs. An update accepted
before capture began may finish installing, but Quill postpones its relaunch
until capture has stopped and its recoverable source state is on disk.

### Recording, degraded

```
Recording — 12:03                                   ⟨disabled⟩
Mic capture lost 4s at 2:35 PM                      ⟨disabled, orange⟩
────────────────────────────────────────────
Stop Recording
Open Last Transcript
…
```

The trouble line lists this session's incidents, sticky, one line each, oldest
first. It stays after recovery; the icon does not.

### Transcribing

```
Quill is idle                                       ⟨disabled⟩
Transcribing 2:14 PM recording — 1 queued           ⟨disabled⟩
────────────────────────────────────────────
Start Recording
Open Last Transcript
…
Check for Updates…
Quit Quill                                      ⌘Q
```

While models are downloading, the line reads
`Downloading transcription models - 42%`. Loading a cached model reads
`Preparing transcription model…`; neither state claims transcription has begun.

### Transcription failed

```
Quill is idle                                       ⟨disabled⟩
Transcription failed — 2:14 PM recording            ⟨enabled, opens transcribe.log⟩
Retry Transcription
────────────────────────────────────────────
Start Recording
Open Last Transcript
…
```

The failure line is clickable, not decoration. If more than one failed, it reads
`2 transcriptions failed` and opens the newest log. `Retry Transcription`
re-enqueues the failed session directly.

### Tooltips

Menu tooltips explain controls without opening Settings. Verbatim:

| Item | `toolTip` |
|---|---|
| Open Recordings Folder | *(the resolved path, e.g.)* `/Users/matt/Recordings` |
| Change Recordings Folder… | `Pick where recordings are saved. Choosing a folder here is also how macOS grants access to protected places like Documents.` |
| Stop Recording and Quit | `Ends the current recording. Transcription resumes the next time Quill starts.` |
| Quit Quill *(while transcribing)* | `Transcription resumes the next time Quill starts.` |

### Mechanics

- **No key equivalents except ⌘Q.** A menu key equivalent only fires while the
  menu is open, so advertising ⌘R promises a hotkey that cannot work from inside
  the meeting being recorded. A real global hotkey is wanted and is a separate
  piece of work.
- **Refresh on open.** Adopt `NSMenuDelegate` and re-read the checkmark state in
  `menuWillOpen(_:)`, so a config edited on disk is not contradicted by a stale
  menu.
- **Persist, then re-read.** A toggle writes to disk and reads the value back, so
  a failed write leaves the checkmark where it was. Keep this.

## 4. Notifications

Seven, total. Every one of them is a terminal event or a thing the user can act
on within a minute.

| # | Trigger | Title | Body | Buttons | Click opens | Interrupts | Status |
|---|---|---|---|---|---|---|---|
| 1 | Recording failed to start | `Recording failed` | `Quill couldn't start recording. Check Microphone and Screen & System Audio Recording permissions.` | — | — | Yes | Ships; **body is a change** |
| 2 | Transcript written | `Transcript ready` | `2:32 PM meeting, 47 minutes` | — | `transcript.md` | Yes | Ships; **body is a change** |
| 3 | Transcription failed | `Transcription failed` | `2:32 PM recording` | `Retry` | `transcribe.log` | Yes | Ships; **body and button are changes** |
| 4 | A track down 30s continuously, or a source archive fails | *see below* | *see below* | — | — | Yes | Ships |
| 5 | Every audible track quiet 10 minutes | `Still recording` | `No one has spoken for 10 minutes. Is the meeting over?` | `Stop Recording` | — | Yes | Ships |
| 6 | Recognized call input active for 2s | `Meeting detected` | `Zen Browser` | `Record` | — | Yes | Ships |
| 7 | Bound call input absent for 2s | `Meeting ended?` | `Zen Browser` | `Stop` | — | Yes | Ships |

Changes to the three that ship: #1 currently interpolates a raw Swift error into
a banner — the error belongs on stderr and in the log, not in front of a person
about to start a meeting. #2 and #3 currently show the session folder name
(`2026.08.10-1432`), a filesystem identifier. #3's `— see transcribe.log` is
redundant when clicking already opens it.

### #4 — an unrecovered track (decision)

**Decided: yes, it interrupts — but only when the track is genuinely gone, not
when it blipped.** The earlier implementation was rejected as noisy because it
fired on `onTrouble`, which fires on every route change over three seconds:
connect a headset mid-meeting and you get a banner. That is the wrong trigger,
not the wrong idea.

The right trigger is duration of continuous failure, and the numbers already in
`CaptureSupervisor` fix it:

| Setting | Value | Why |
|---|---|---|
| Threshold | **30 seconds continuously unhealthy** | Route changes settle in 1-5s (`stallTimeout` is 5s). Rebuild backoff caps at 15s by attempt 6, so a track still down at 30s has failed four rebuilds and is not recovering on its own. |
| Frequency | **Once per session, per track** | A track that stays dead is not re-announced. Recovery followed by another loss does not re-fire. |
| Combining | Both tracks down at once is **one** notification, not two | |
| Buttons | **None** | At 30 seconds the useful response is physical — reconnect the headset, check the meeting app is still playing. There is no button for that, and "Stop Recording" is the wrong advice while the other track is still good. |
| Click | Nothing | An accessory app has nothing to bring forward. |

Copy:

| Case | Title | Body |
|---|---|---|
| Mic | `Microphone stopped` | `Still recording the call, but nothing from your mic for 30 seconds. Reconnect your input device.` |
| System | `System audio stopped` | `Still recording your mic, but nothing from the call for 30 seconds. Check the meeting app is still playing.` |
| Both | `Recording is empty` | `Neither track has captured anything for 30 seconds. Quill is still running.` |

A source archive failure is different from a stalled capture graph. Audio
reached Quill but its AAC writer could not save another buffer, so waiting 30
seconds or rebuilding the device graph cannot repair it. The affected source is
closed permanently and the notification fires immediately:

| Case | Title | Body |
|---|---|---|
| Mic archive | `Microphone recording stopped` | `Quill couldn't save more microphone audio. The call is still being recorded.` |
| System archive | `System audio recording stopped` | `Quill couldn't save more call audio. Your microphone is still being recorded.` |
| Both archives | `Recording stopped` | `Quill couldn't save any more audio. Quill will try to recover audio already written.` |

One failed archive leaves the companion degraded and the surviving track
running. Two failed archives stop the session automatically because continued
recording would preserve nothing.

### #5 — the silence nudge (decision)

**Decided: fires once per session at 10 minutes, with a `Stop Recording`
button.**

The failure it prevents is a four-hour recording of an empty room, and the cost
of a false positive is one dismissal. That asymmetry justifies interrupting.

**Signal.** "Quiet" is defined differently per track, and this must not be
confused with the fault detection already in `TrackWriter`:

| Track | Quiet means | Note |
|---|---|---|
| Mic | RMS below **-50 dBFS** | Exact zero on the mic already means a *dead route* and triggers a rebuild. A live mic in a silent room has a noise floor, so the nudge needs a level floor, not zero. |
| System | peak == 0 | Exact zero is genuinely "nothing is playing". `watchSilence` is off for this track and **must stay off** — this signal feeds the nudge only, never the supervisor, or the system tap will be rebuilt every time playback pauses. |

**Rules:**

| Rule | Value |
|---|---|
| Which tracks count | Only tracks that have produced audio at some point this session. An in-person meeting never plays anything, so the system track is silent from the first second to the last; counting it would fire the nudge ten minutes into a real meeting. A track nobody has heard from is not evidence. |
| Threshold | 10 minutes of every counting track quiet, continuously |
| Reset | Any non-quiet buffer on **any** counting track resets the clock. Not cumulative. |
| No track counts | Nothing has ever been audible on either track. That is a broken capture, not a finished meeting, and belongs to #4. Never nudge. |
| Frequency | Once per session. Dismissed means never again this session. |
| Suppressed when | Either track is degraded — a dead route produces silence, and that is #4's job, not this one. The two must never both fire. |
| Button | `Stop Recording` — stops the session exactly as the menu item does, and transcription follows normally. |
| Dismissing | Means "keep recording". There is no `Keep Recording` button; a button that does nothing is noise. |
| Sound | Yes. By construction nothing has been audible for ten minutes, so a chime cannot interrupt a meeting. |

**Why ten minutes.** A legitimately quiet stretch — reading a shared document, a
pause while someone finds a file — runs one to three minutes. Nobody speaking
*and* nothing playing for ten minutes is not a meeting in progress. Shorter and
it fires during real lulls, which teaches the user to ignore it; much longer and
the thing it exists to prevent has mostly already happened. The cost of being
wrong is ten minutes of junk audio and about four seconds of transcription.

### #6 and #7: call lifecycle prompts

The menu app observes audio-input processes once per second. It normalizes
recognized application families and requires two continuous seconds before
either prompt. Initial state establishes a baseline and never produces a false
start at launch.

The start action is the only path that binds a recording to the detected app.
Manual recordings never inherit a call association. The end prompt appears only
for that bound recording, and stopping remains explicit because mute, route
changes and browser navigation can all interrupt input without ending a call.
Unknown input processes are logged but never prompt.

Both prompts request banner and Notification Center list presentation. A banner
covered by another app remains recoverable from Notification Center. If a bound
application recovers after an end prompt, Quill removes that prompt and rejects
its action if it is already in flight.

Notification permission is requested when the first stable call is detected or
the first manual recording starts, whichever happens first. It is never
requested merely because Quill launched.

### Quill must not speak

| Moment | Instead |
|---|---|
| Recording started | The icon changes shape. That is the confirmation. |
| Recording stopped | Same, and the transcript notification follows. |
| A capture blip under 30 seconds | The icon goes orange and back. |
| A track recovering | Nobody needs to be told a problem they were never told about has gone away. |
| Second and later faults on the same track | Once per track per session. |
| Each queued transcription starting | Only completion speaks. |
| Model download starting or finishing | Menu line only. |
| A track skipped as missing or empty during transcription | `.quill/transcribe.log`. |
| Speaker separation failing | The review window preserves the baseline transcript and offers Retry. |
| Anything at launch | Including the notification permission prompt. It is asked at the first stable call or first recording, when the reason is visible. |

## 5. Config

Three surfaces, with one job each: **the menu operates Quill; Settings
administers Quill; JSON holds code-facing configuration.** Menu controls may
persist, but their placement is determined by when someone needs them, not by
which subsystem reads the value.

| Setting | Home | Why |
|---|---|---|
| Speaker review | Task-scoped review window | Optional enrichment after the baseline transcript exists. |
| Open at login | Settings | Durable application lifecycle behaviour, backed by `SMAppService`, not a meeting control. `install --launch-at-login` remains a thin wrapper over the same call. |
| Recordings folder | Settings + conditional menu recovery | Settings owns the persistent location. `Change Recordings Folder…` appears in the menu only when folder access is broken, because choosing through the panel is also the permission repair. |
| Audio retention | Settings | The choice can irreversibly delete source audio and needs explanatory copy plus confirmation. |
| `transcription.engine` | Static Settings text + JSON | One engine ships. Settings reports Parakeet as information; it does not present a disabled fake choice. |
| Transcription models | Settings + conditional menu recovery | Settings reports the engine, expected or installed size, and Download / Remove. A download command appears in the menu only when automatic download is blocked or fails. |
| `on_stop` | JSON, permanently | It is a shell command. A shell command never gets a GUI field. |

The Settings window is three administrative groups:

1. **General:** Open at login; recordings folder path and Change…
2. **Storage:** source-audio retention (keep indefinitely / keep 30 days /
   delete after transcription)
3. **Transcription:** static engine identity; model status and expected or
   installed size; Download / Remove

Recording always produces a transcript. Speaker separation has no persistent
setting in this slice and stores its result in the transcript document.

### Audio retention

The default is `Keep indefinitely`. The original tracks are the source for
verification and future re-transcription, so Quill never removes them without
an explicit user choice.

Both destructive choices require confirmation when selected. `Keep for 30 days`
uses `created_at` from `.quill/transcript.json`, falling back to its modification date
for older transcripts. `Delete after transcription` becomes eligible as soon as
that file exists. In both cases Quill deletes `Source Audio/` and any legacy CAF
working files. `Meeting Audio.m4a`, metadata, logs and transcripts remain.
Reprocessing and voice samples are unavailable once source audio is deleted;
the confirmation says so.

Cleanup runs after a successful transcript, at launch, when the recordings
folder changes, and daily while Quill stays open. A configured `on_stop` command
must terminate before cleanup touches that session's audio.

## 6. Copy rules

**Capitalisation.**

| Kind | Case | Examples |
|---|---|---|
| Menu commands and checkboxes | Title case | `Start Recording`, `Open Last Transcript`, `Review Last Transcript…`, `Quit Quill` |
| Settings labels and checkboxes | Sentence case | `Open at login`, `Source audio` |
| Status lines | Sentence case | `Quill is idle`, `Recording — 12:03`, `Mic capture lost 4s at 2:35 PM` |
| Notification titles | Sentence case | `Transcript ready`, `Microphone stopped` |
| The app's name | `Quill` in the UI, `quill` for the binary and the command | |

**Terminology.** Two tracks, two names, used consistently everywhere the user
can see:

| Track | User-facing word | Never |
|---|---|---|
| `mic.caf` | **microphone**, or **local** as source context after separation | "input" |
| `system.caf` | **system audio**, or **remote** as source context after separation | "output", "loopback" |

Use "speakers" only in explicit transcript-review context, where it means
people unambiguously. Use "voices" when describing captured sound. Baseline
transcript labels are `Me` and `Them`. After separation, unnamed voices are
globally numbered `Voice 1`, `Voice 2` and so on.

**Durations.**

| Where | Format | Example |
|---|---|---|
| Status item and menu status line | `m:ss`, `h:mm:ss` past an hour | `12:03`, `1:04:22` |
| Prose (notifications, tooltips) | Words | `47 minutes`, `1 hour 12 minutes`, `less than a minute` |
| Never | | `72 min`, `1.2h`, `0:47` in prose |

**Session names.** `2026.08.10-1432` is a filesystem identifier and never
appears in the UI. Render it:

| When | Format | Example |
|---|---|---|
| Today | `h:mm a` | `2:32 PM recording` |
| Within a week | `EEE h:mm a` | `Sat 2:32 PM recording` |
| Older | `d MMM, h:mm a` | `10 Aug, 2:32 PM recording` |

The word after the time is `recording` in most places and `meeting` in the
transcript-ready notification, where the thing being announced is the meeting,
not the file.

## 7. End-to-end meeting workflow

### Meeting companion

The custom surface is one non-activating meeting companion, not a parallel menu
or a custom implementation of every notification:

| State | Content | Exit |
|---|---|---|
| Detected | Application, `Record`, 12-second deadline | Record, dismiss, timeout, or call ends |
| Recording, brief/expanded | Red dot, elapsed time, `Stop` | Collapses after three seconds |
| Recording, collapsed | Small record capsule and ellipsis | Expand controls or possible end |
| Possible end | `Meeting ended?`, application, `Stop` | Stop, Keep Recording, or input recovery |
| Stopping | `Saving recording…` | Processing |
| Processing | `Creating transcript…` | Ready or dismiss |
| Ready while visible | `Transcript ready`, `Review` | Review or dismiss |

The expanded companion is 380 × 72 points. It appears without activating Quill
or stealing keyboard focus. A deliberate interaction may make it key for
keyboard or VoiceOver use. In Recording, Escape and the right-chevron control collapse
the controls back to the pill; in other states they dismiss the surface. Quill
places the first appearance at the top right near system notifications. A drag
changes the default position for later sessions and application launches; state
changes and elapsed updates never recenter it. Expansion and collapse preserve
the same right edge and vertical centre. If the saved position is no longer on
a connected display, Quill returns to the top right of the main display. It
joins full-screen Spaces and never stacks a second surface.

During a detected recording, the quiet subtitle remains the detected
application name. A manual recording has no subtitle. Normal capture does not
repeat `microphone and computer audio`; capture failures replace the subtitle
with an actionable exception instead.

An unanswered Detected prompt expires after 12 seconds. A two-point accent bar
drains across its lower edge to make that deadline visible. Timeout means "not
this meeting" and suppresses another prompt for the same active call episode.

After recording begins, the expanded controls remain for three seconds, then
collapse to a 48 × 72-point recording capsule. The capsule is confidence, not a
second workflow: a red record glyph and ellipsis only. The entire capsule is a
combined click-or-drag target, so a click restores the expanded controls for
eight seconds and a drag moves it from almost anywhere. Hovering the expanded
controls extends their stay to eight seconds but never prevents collapse
indefinitely. `Show Recording
Controls` in the menu provides the same expansion. Possible end expands
automatically because it requires a decision.

Dismissing Detected suppresses the rest of that application's current active
episode. Recording's right chevron cannot hide capture confidence; it returns to the pill,
and the menu exposes `Show Recording Controls`. If input disappears, Possible
end replaces the pill because it requires an explicit decision.

Native notifications retain a distinct role. They report failures and deliver
transcript completion when the person dismissed processing. Dismissal never
cancels work. If the companion remains visible, it stays on `Creating
transcript…` until completion and becomes `Transcript ready`. Both completion
surfaces open the same Quill review window.

### Transcript-first speaker flow

Recording and initial transcription have no speaker-separation setting. Quill
always captures both tracks and produces a baseline transcript with coarse
`Me` and `Them` labels.

`Review Last Transcript…` opens a task-scoped, read-only window after the
transcript exists. The transcript is the primary content. Its Speakers sidebar
lets the user sample and name `Me` and `Them` immediately. `Separate Remote
Voices` and `Separate Local Voices` appear below them when their respective
source audio is available. The user chooses the source based on the shape of the
meeting; the actions never implicitly process the other track.
While this task window is open, Quill temporarily appears in the Dock and
Command-Tab switcher. Closing it returns Quill to its menu-bar-only accessory
state. The transcript window remains part of the same app and process.
Either action starts local analysis directly. The review window stays open until
success or failure, and an active recording blocks the action with an explicit
explanation. The existing timed words remain authoritative:
Quill runs diarisation against retained source audio and reassigns speaker
metadata without rerunning speech recognition.

Before analysis, Quill asks how many distinct people spoke on that track. The
Remote question excludes the user; the Local question includes everyone near
the Mac. Counts from 2 through 20 select exact-count VBx clustering. `Detect
automatically (less reliable)` is an explicit fallback rather than the default.

The operation is serialised with transcript work. It shows model preparation,
real completed-chunk progress while the selected source is analysed, then an
indeterminate clustering stage and transcript update. It stages the enriched
document and atomically publishes `.quill/transcript.json` and `transcript.md`;
failure leaves the baseline unchanged. Separating one source preserves the
other source's coarse identity. A track with one detected person still
receives a nameable voice ID. Speech that cannot be attributed remains
unassigned rather than being forced onto a person.

Before first separation, Quill preserves the exact baseline transcript. After a
successful result, `Undo Voice Separation` restores `Me` and `Them`, including
their saved names, and removes separated voice names. Sessions processed by an
older version have no snapshot and cannot offer exact undo without rerunning
speech recognition. `Run Voice Separation Again` reuses the preserved baseline
with a new speaker count while retaining the current separated result until its
replacement succeeds.

### Finished session audio

CAF remains the active capture container because audio already written survives
an interrupted recording. It is not the finished format. A normally completed
session presents:

```text
Meeting Audio.m4a
transcript.md
Source Audio/
  Local.m4a
  Remote.m4a
  Local Cleaned.m4a
.quill/                  hidden internal state
```

`Meeting Audio.m4a` combines the echo-cleaned microphone and call tracks for
ordinary playback and sharing. It is mono AAC because neither source retains
spatial information. On a normal recording the live echo-cancellation pump
builds it incrementally; recovery can rebuild the same artifact from retained
source tracks. The separate tracks support voice samples, verification and
reprocessing. With Finder's normal hidden-file setting, the root presents only
the three human-facing items. `.quill/` contains metadata, recovery journals,
canonical transcript data, logs, clock observations, temporary CAF capture
files and M4A staging.

Finalization keeps CAF inputs until each M4A has the expected duration and
decodes completely, then publishes new metadata atomically before deleting the
working files. A capture journal written before the audio taps start lets Quill
reconstruct metadata and finalize surviving CAF files after interruption. File
consumers resolve paths through `.quill/meta.json`; they do not infer `.caf` or `.m4a`.
There is no WAV export: the capture is already AAC, so WAV would add size
without adding information. Older session layouts are not migrated.

### Reviewing speakers

A focused Quill window presents the readable transcript and names stable
machine voice IDs. It is not a general transcript editor. After optional
separation its Speakers sidebar presents:

```text
Who is speaking?
Voice 1   local      [ Name this voice ]  ▶ Play Sample
Voice 2   remote     [ Alice           ]  ▶ Play Sample
```

Each voice offers up to three representative samples. The first click plays the
best candidate; `Another Sample` advances through alternatives. Candidate
ranking favors a useful three-to-eight-second duration and enough recognized
words to identify the person. Playback seeks into the appropriate source track;
no extracted clip file is required.
Voice numbers are unique across the recording. Source appears as quiet
secondary context in native review and remains visible after naming, but is not
part of the voice name or post-separation Markdown.
Before separation, `Me` and `Them` can be named without running diarisation. If
a named source produces exactly one separated voice, its name carries forward.
If it produces several, none inherits the group name.
If retention removed the source track, existing names remain editable and only
the sample control becomes unavailable.

Assigning `Alice` changes the human label mapped to the stable machine ID and
updates every segment in that cluster. It does not rewrite diarization output.
Per-sentence reassignment and cluster merging are outside the first scope.
Markdown remains the editable and export artifact. `Open Transcript File` and
`Show in Finder` are explicit actions in the review window. The native review is
justified by a coherent completion flow, audio playback and identity management
that Markdown cannot do.
Those file actions sit at the footer's left. `Close` and, after separation,
`Save Names` sit at the right. Standard window controls remain available.
The first speaker name receives initial keyboard focus. Tab follows visible
control order and includes each sample button; Return advances directly through
the name fields and saves from the final name. Rebuilding the review after a
save or speaker-separation state change preserves the focused control when that
control still exists.
While review gives Quill regular application presence, its standard Edit menu
routes Cut, Copy, Paste, Undo and Select All through the focused text control.
Copy therefore works in the selectable transcript, while Quit still completes
Quill's recording shutdown path.
Closing with changed names offers Save, Don't Save and Cancel; closing never
implies that optional speaker review is complete.
The stable IDs, human label map and segments live together in schema v1 of the
canonical `.quill/transcript.json`, which is rewritten atomically with `transcript.md`;
there is no second label database or sidecar. Incompatible JSON is ignored by
voice review without affecting Quill or the readable Markdown.
Model and diarizer provenance stays in the internal JSON. It does not appear in
the human-facing Markdown.

## 8. Deliberately not doing

| | Why |
|---|---|
| Pause and resume | Two tracks share one wall clock; a pause is a gap to reconcile in both, for a feature that "stop and start again" already covers. |
| Per-app audio picker | The global tap is the feature. Filtering it is a preferences pane and a support burden for "don't play Spotify". |
| Level meters or a waveform | The menu bar is not a mixer, and the elapsed counter already proves capture is alive. |
| A general transcript editor | `transcript.md` remains the editable and export artifact. Quill's native window is read-only review plus speaker identification. |
| A permanent Dock icon | Quill is normally a menu bar accessory. It becomes a regular app only while transcript review is open, so that task window participates in Command-Tab. |
| Our own sounds | The system's notification sound is the only sound quill makes. |
| A first-run wizard | Permissions prompt themselves and the operational menu is already the onboarding surface. If more onboarding is needed, the menu is wrong. |
| Live transcription during the meeting | Doubles the compute during the one moment the machine is busy, to show text nobody reads while talking. |
| Progress in the status item | See principle 1. The bar reports recording. |
| Any cloud, any account, any telemetry | Nothing leaves the machine. This is the product. |
