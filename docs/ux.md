# Quill UX

The design of the only surface quill has: a menu bar item, its menu, and its
notifications. Prescriptive. Where something is not built yet it is marked
**Proposed**; everything else is what ships today.

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
5. **A setting stays in the menu until its title plus a tooltip cannot explain
   it.** That is the trigger for building a window, and only then.
6. **No wizards, no panes, no windows.** The app is a menu and three
   notifications. If a feature needs more than that, it needs a better design.

## 2. Status item

Set once at launch: `statusItem.autosaveName = "com.mattdoran.quill.status"`, so
the item keeps the position the user dragged it to. *(Proposed.)*

| State | Glyph | Tint | Button title | Accessibility title |
|---|---|---|---|---|
| Idle | feather (inline SVG, template) | none | *(empty)* | `Quill, idle` |
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
- Accessibility titles are spelled out for speech, not read off the clock face.
  *(Currently they pass the raw `12:03` — proposed change.)*

## 3. Menu

Title case on commands, sentence case on status lines. `✓` marks a checkmark,
`⟨disabled⟩` marks a greyed, unclickable item.

Status lines are disabled but must not be low-contrast: set `attributedTitle`
with `.labelColor` (and `.systemOrange` for the trouble line). The one thing the
user opened the menu to read cannot be the dimmest text in it. *(Proposed.)*

### Idle

```
Quill is idle                                       ⟨disabled⟩
Open Last Transcript
────────────────────────────────────────────
Start Recording
Open Recordings Folder
────────────────────────────────────────────
Separate Voices in the Room                      ✓
Separate Voices on the Call                      ✓
Cancel Echo from Speakers
Transcribe After Recording                       ✓
────────────────────────────────────────────
Open at Login                                    ✓
About Quill
Quit Quill                                      ⌘Q
```

`Open Last Transcript` is disabled when no session has a `transcript.md`.

### Recording

```
Recording — 12:03                                   ⟨disabled⟩
Open Last Transcript
────────────────────────────────────────────
Stop Recording
Open Recordings Folder
────────────────────────────────────────────
Separate Voices in the Room                      ✓
Separate Voices on the Call                      ✓
Cancel Echo from Speakers                           ⟨disabled⟩
Transcribe After Recording                       ✓
────────────────────────────────────────────
Open at Login                                    ✓
About Quill
Stop Recording and Quit                         ⌘Q
```

The two speaker toggles stay live while recording: they are read at
transcription time, so a mid-meeting change still lands. Echo cancellation is
not, because it is applied when the mic graph is built.

### Recording, degraded

```
Recording — 12:03                                   ⟨disabled⟩
Mic capture lost 4s at 2:35 PM                      ⟨disabled, orange⟩
Open Last Transcript
────────────────────────────────────────────
Stop Recording
…
```

The trouble line lists this session's incidents, sticky, one line each, oldest
first. It stays after recovery; the icon does not.

### Transcribing

```
Quill is idle                                       ⟨disabled⟩
Transcribing 2:14 PM recording — 1 queued           ⟨disabled⟩
Open Last Transcript
…
Quit Quill                                      ⌘Q
```

While the models are downloading, the line reads
`Preparing transcription model — 42%`. It must not read "transcribing": today
`.transcribing` is published before the engine is prepared, so a 600 MB
first-run download reads as transcription for minutes. Publish a `.preparing`
state first. *(Proposed.)*

### Transcription failed

```
Quill is idle                                       ⟨disabled⟩
Transcription failed — 2:14 PM recording            ⟨enabled, opens transcribe.log⟩
Retry Transcription
Open Last Transcript
…
```

The failure line is clickable, not decoration. If more than one failed, it reads
`2 transcriptions failed` and opens the newest log. `Retry Transcription`
re-enqueues; today the only recovery is quitting and relaunching so
`resumePending` finds it, which is not a recovery story. *(Proposed.)*

### Tooltips

`NSMenuItem.toolTip` is the thing that keeps settings in the menu instead of in
a window. Verbatim:

| Item | `toolTip` |
|---|---|
| Open Recordings Folder | *(the resolved path, e.g.)* `/Users/matt/Recordings` |
| Separate Voices in the Room  | `Labels each person on your microphone track separately, for in-person meetings. Downloads a second on-device model the first time.` |
| Separate Voices on the Call  | `Labels each person on the call separately, for group calls. Downloads a second on-device model the first time.` |
| Cancel Echo from Speakers | `Stops meeting audio bleeding into your microphone when you are not wearing headphones. Slightly quietens other playback while recording. Applies to the next recording.` |
| Transcribe After Recording | `Off means quill records only. Turning it back on transcribes the backlog the next time Quill starts.` |
| Open at Login | `Quill starts hidden in the menu bar when you log in. macOS also lists it under System Settings → General → Login Items.` |
| Stop Recording and Quit | `Ends the current recording. Transcription resumes the next time Quill starts.` |
| Quit Quill *(while transcribing)* | `Transcription resumes the next time Quill starts.` |

### Mechanics

- **No key equivalents except ⌘Q.** A menu key equivalent only fires while the
  menu is open, so advertising ⌘R promises a hotkey that cannot work from inside
  the meeting being recorded. A real global hotkey is wanted and is a separate
  piece of work.
- **Refresh on open.** Adopt `NSMenuDelegate` and re-read the checkmark state in
  `menuWillOpen(_:)`, so a config edited on disk is not contradicted by a stale
  menu. *(Proposed.)*
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
| 4 | A track down 30s continuously | *see below* | *see below* | — | — | Yes | **Proposed** |
| 5 | Both tracks quiet 10 minutes | `Still recording` | `No one has spoken for 10 minutes. Is the meeting over?` | `Stop Recording` | — | Yes | **Proposed** |

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
| Anything at launch | Including the notification permission prompt, which should be requested on the first *stop*, seconds before the first notification fires — not at login. *(Proposed.)* |

## 5. Config

Three homes, and the rule for which is which: **the menu holds anything a user
would change between meetings; JSON holds anything that is really code; a window
holds nothing until it holds something the menu cannot.**

| Setting | Home | Why |
|---|---|---|
| Separate voices, mic | Menu | Changes per meeting: in-person or not. |
| Separate voices, system | Menu | Changes per meeting: group call or 1:1. |
| Echo cancellation | Menu | Changes per meeting: headphones or speakers. Disabled while recording. |
| Transcribe after recording | Menu | One line explains it. |
| Open at Login | Menu | Via `SMAppService`; `install --launch-at-login` retires. |
| Recordings folder | Menu, read-only | The resolved path as the `Open Recordings Folder` tooltip. Changing it is rare enough for JSON. |
| `transcription.engine` | JSON | One value ships. Not a setting yet. |
| `on_stop` | JSON, permanently | It is a shell command. A shell command never gets a GUI field. |

**Trigger for building a Settings window:** when a setting exists that a title
plus a tooltip cannot explain, *and* it is not `on_stop`. Two of the backlog
items will trip it and nothing else currently will:

- **Audio retention** — keep or discard the tracks after transcription, and for
  how long. A retention window is a number with consequences; it is not a
  checkbox.
- **Model management** — download progress, cache size, re-download.

When that window is built, it contains exactly five things and nothing else:

1. Recordings folder (path, with a Change… button)
2. Audio retention (keep / discard / keep for N days)
3. Transcription: on/off, engine
4. Echo cancellation
5. Models: status, size, Download / Remove

Everything in the menu that is per-meeting — start/stop, open last transcript,
the two speaker toggles, open folder, quit — stays in the menu. Duplicating a
control into both is allowed only for echo cancellation and transcription
on/off, which are per-meeting *and* belong beside their neighbours.

**Known trap:** `state.json` overrides `config.json` for the speaker toggles, so
a user who has ever clicked either menu item will find later hand-edits to
`config.json` silently ignored. Resolving the two files into one home is a
backlog item; until then the precedence must be documented where the user reads
it, not only in a source comment.

## 6. Copy rules

**Capitalisation.**

| Kind | Case | Examples |
|---|---|---|
| Commands and checkboxes | Title case | `Start Recording`, `Open Last Transcript`, `Transcribe After Recording`, `Quit Quill` |
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
