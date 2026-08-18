# Quill UX

The design of Quill's menu bar item, menu, Settings window and notifications.
Prescriptive. Where something is not built yet it is marked **Proposed**;
everything else is what ships today.

## 1. Principles

1. **The menu bar reports one thing: whether quill is recording.** Nothing else
   ever changes the icon. Transcription, downloads and queues live in the menu.
2. **Nothing animates.** Nothing in the macOS menu bar blinks, and the elapsed
   counter is already the motion that catches the eye.
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
7. **One utility window, no workflows.** Settings is allowed. Wizards,
   transcript viewers and recording windows are not.

## 2. Status item

Set once at launch: `statusItem.autosaveName = "com.mattdoran.quill.status"`, so
the item keeps the position the user dragged it to.

| State | Glyph | Tint | Button title | Accessibility title |
|---|---|---|---|---|
| Idle | feather (inline SVG, template) | none | *(empty)* | `Quill, idle` |
| Starting | `record.circle` | none | *(empty)* | `Quill, starting recording` |
| Recording | `record.circle.fill` | `.systemRed` | ` 12:03` | `Quill, recording, 12 minutes 3 seconds` |
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
Open Recordings Folder
────────────────────────────────────────────
Transcribe After Recording                       ✓
Separate Voices in the Room                      ✓
Separate Voices on the Call                      ✓
────────────────────────────────────────────
Settings…
About Quill
Quit Quill                                      ⌘Q
```

`Open Last Transcript` is disabled when no session has a `transcript.md`.
`Retry Transcription` and `Download Transcription Models` are hidden unless they
apply, and appear in the status block at the top. `Change Recordings Folder…`
appears below `Open Recordings Folder` only when Quill cannot read that folder.

### Recording

```
Recording — 12:03                                   ⟨disabled⟩
────────────────────────────────────────────
Stop Recording
Open Last Transcript
Open Recordings Folder
────────────────────────────────────────────
Transcribe After Recording                       ✓
Separate Voices in the Room                      ✓
Separate Voices on the Call                      ✓
────────────────────────────────────────────
Settings…
About Quill
Stop Recording and Quit                         ⌘Q
```

During audio-device attachment, the status line reads `Starting recording…`
and the command beneath it reads `Starting Recording…` disabled. The menu-bar
glyph changes immediately, but its title stays empty so startup does not widen
and then shrink the status item.

Nothing in the settings block greys out while recording. Every item there is
settable mid-meeting; they differ only in when the setting takes effect, which
is a job for the tooltip, not for a grey row.

### The settings block: ordering and greying

Three persistent controls, one block: whether to transcribe, then how to label
the result.

| Order | Item | Why here |
|---|---|---|
| 1 | `Transcribe After Recording` | The master switch for the two below. A setting cannot sit underneath the thing that gates it. |
| 2 | `Separate Voices in the Room` | Depends on 1; greys out with it. |
| 3 | `Separate Voices on the Call` | Its pair, adjacent, differing only in the last two words on purpose. |

Decisions this settles:

- **One block, not three.** All three answer the same question: what Quill should
  do with the next recording. They persist until changed, but they are kept in
  the operational surface because physical setup and meeting type change.
  Splitting them by which subsystem reads them is an implementation detail
  leaking into a menu.
- **Pipeline order beats frequency order.** Frequency of change would put the two
  Separate Voices toggles first, which is roughly what shipped. It loses because
  it puts a dependent setting above its master, and no amount of frequency
  justifies that.
- **The two `Separate Voices` items grey out when `Transcribe After Recording`
  is off.** They configure a pipeline that will not run. The rule that makes this
  safe: **grey an item only when the cause is visible in the same menu.** An
  unchecked master one line above is visible. A tooltip is not.
- **Parallel construction on the pair stays.** They are a matched choice on two
  tracks; the shared prefix is the signal that they are a pair, and adjacency
  does the disambiguating. Front-loading the difference would read worse and
  break the pairing.
- **No section headers.** `NSMenuItem.sectionHeader(title:)` exists on macOS 14+
  and is not warranted for three items already fenced by separators. Any honest
  header text is either redundant with the position or vague, and headers on a
  fifteen-item menu make it look like the preferences pane this app refuses to
  have. Indentation under the master (`NSMenuItem.indentationLevel`) was
  considered and dropped: greying the dependants already carries the
  relationship, so the indent adds layout risk for nothing.

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
| Separate Voices in the Room  | `Labels each person on your microphone track separately, for in-person meetings. Downloads a second on-device model the first time.` |
| Separate Voices on the Call  | `Labels each person on the call separately, for group calls. Downloads a second on-device model the first time.` |
| Transcribe After Recording | `Off means quill records only. Turning it back on transcribes the backlog the next time Quill starts.` |
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

Five, total. Three ship today; two are proposed. Every one of them is a terminal
event or a thing the user can act on within a minute.

| # | Trigger | Title | Body | Buttons | Click opens | Interrupts | Status |
|---|---|---|---|---|---|---|---|
| 1 | Recording failed to start | `Recording failed` | `Quill couldn't start recording. Check Microphone and Screen & System Audio Recording permissions.` | — | — | Yes | Ships; **body is a change** |
| 2 | Transcript written | `Transcript ready` | `2:32 PM meeting, 47 minutes` | — | `transcript.md` | Yes | Ships; **body is a change** |
| 3 | Transcription failed | `Transcription failed` | `2:32 PM recording` | `Retry` | `transcribe.log` | Yes | Ships; **body and button are changes** |
| 4 | A track down 30s continuously | *see below* | *see below* | — | — | Yes | Ships |
| 5 | Every audible track quiet 10 minutes | `Still recording` | `No one has spoken for 10 minutes. Is the meeting over?` | `Stop Recording` | — | Yes | Ships |

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
| A track skipped as missing or empty during transcription | `transcribe.log`. |
| Diarization failing | It degrades to the flat label and the transcript still exists. Log only. |
| Anything at launch | Including the notification permission prompt. It is asked the first time a recording starts: asking at the first *stop*, as originally written here, would miss the failed-to-start notification, which is the one a fresh install is most likely to need. |

## 5. Config

Three surfaces, with one job each: **the menu operates Quill; Settings
administers Quill; JSON holds code-facing configuration.** Menu controls may
persist, but their placement is determined by when someone needs them, not by
which subsystem reads the value.

| Setting | Home | Why |
|---|---|---|
| Separate voices, mic | Menu | Chosen from the meeting context: in-person or not. |
| Separate voices, system | Menu | Chosen from the meeting context: group call or 1:1. |
| Echo cancellation | Menu | A situational capture choice for loudspeakers versus headphones. Defaults **off**: measurement put the cost at 7.8 dB on the recorded system track. A mid-recording click applies to the next recording. |
| Transcribe after recording | Menu | An operational switch used before a recording. It persists and gates the two Separate Voices toggles. A second label in Settings made one value look like two behaviours. |
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

Echo cancellation and voice separation remain in the menu only. All values
share one file at `~/Library/Application Support/Quill/config.json`.

### Audio retention

The default is `Keep indefinitely`. The original tracks are the source for
verification and future re-transcription, so Quill never removes them without
an explicit user choice.

Both destructive choices require confirmation when selected. `Keep for 30 days`
uses `created_at` from `transcript.json`, falling back to its modification date
for older transcripts. `Delete after transcription` becomes eligible as soon as
that file exists. In both cases Quill deletes only `mic.caf` and `system.caf`.
Metadata, logs and transcripts remain.

Cleanup runs after a successful transcript, at launch, when the recordings
folder changes, and daily while Quill stays open. A configured `on_stop` command
must terminate before cleanup touches that session's audio.

## 6. Copy rules

**Capitalisation.**

| Kind | Case | Examples |
|---|---|---|
| Menu commands and checkboxes | Title case | `Start Recording`, `Open Last Transcript`, `Transcribe After Recording`, `Quit Quill` |
| Settings labels and checkboxes | Sentence case | `Open at login`, `Source audio` |
| Status lines | Sentence case | `Quill is idle`, `Recording — 12:03`, `Mic capture lost 4s at 2:35 PM` |
| Notification titles | Sentence case | `Transcript ready`, `Microphone stopped` |
| The app's name | `Quill` in the UI, `quill` for the binary and the command | |

**Terminology.** Two tracks, two names, used consistently everywhere the user
can see:

| Track | User-facing word | Never |
|---|---|---|
| `mic.caf` | **microphone**, or **the room** when talking about who is on it | "input", "local", "me" |
| `system.caf` | **system audio**, or **the call** when talking about who is on it | "output", "remote", "them", "loopback" |

"Speakers" is banned as a word for people. On an audio app it reads as
loudspeakers first, which is why `Detect speakers in the room` had to go. Use
"voices" for people and "speakers" only for hardware.

`me` / `them` / `room 1` remain the *transcript* labels. Those are data, not UI
copy, and are not covered by this rule.

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

## 7. Deliberately not doing

| | Why |
|---|---|
| Pause and resume | Two tracks share one wall clock; a pause is a gap to reconcile in both, for a feature that "stop and start again" already covers. |
| Per-app audio picker | The global tap is the feature. Filtering it is a preferences pane and a support burden for "don't play Spotify". |
| Level meters or a waveform | The menu bar is not a mixer, and the elapsed counter already proves capture is alive. |
| A transcript viewer window | `transcript.md` opens in whatever the user already reads Markdown in. Writing a worse one is not a feature. |
| A Dock icon, ever | `LSUIElement` is declared in the plist and set at runtime. It is a menu bar app. |
| Our own sounds | The system's notification sound is the only sound quill makes. |
| A first-run wizard | Permissions prompt themselves and the menu is thirteen items. If onboarding is needed, the menu is wrong. |
| Live transcription during the meeting | Doubles the compute during the one moment the machine is busy, to show text nobody reads while talking. |
| Progress in the status item | See principle 1. The bar reports recording. |
| Any cloud, any account, any telemetry | Nothing leaves the machine. This is the product. |
