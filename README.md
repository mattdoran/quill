# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no Xcode.

Starting a fresh session? Read these in order:

| File | Purpose |
|---|---|
| `README.md` | Install, run and configure Quill. |
| `docs/ux.md` | The current product and UI design. |
| `docs/decisions.md` | Settled decisions and their reasons. |
| `docs/open-questions.md` | Possible product paths that still need investigation or a decision. |
| `TODO.md` | Work that remains. |

## Install

```sh
cd quill
swift build -c release
./bundle.sh                                   # wraps the binary in Quill.app
./install.sh                                  # installs and restarts Quill
./build-dmg.sh                                # optional distributable image
```

`install.sh` installs to `~/Applications/Quill.app`, replaces
`~/.local/bin/quill` with a symlink to the bundle executable, and always quits
and relaunches Quill. The app bundle is the single installed copy of the code.

For a distributable release, notarize the reviewed app before building the
image around it:

```sh
swift build -c release
./bundle.sh --notarize
./build-dmg.sh --notarize
```

See `signing.conf.example` for the one-time Developer ID and notarization
credential setup. The finished image is `.build/release/Quill-<version>.dmg`.

The `.app` wrapper is what gives quill its own identity: notifications that
carry its name and open the transcript when clicked, rather than arriving as
anonymous banners. It is still one SwiftPM binary and no Xcode — the bundle is
two folders around it.

Open at login is enabled on the first bundled launch. It registers as a normal
login item, so you can change it in Quill Settings or in System Settings →
General → Login Items. Startup is tied to where the app lives, so move it before
the first launch rather than afterwards.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or launch `Quill.app`).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

When a recognized calling app uses audio input continuously for two seconds,
Quill shows a compact meeting companion with `Record`. A recording started from
that action is bound to the detected app; when its input ends for two seconds,
the same companion asks whether to stop. It stays with the recording through
saving and short transcript processing. Neither transition starts or stops
recording without an explicit action.

Each session lands in `~/Music/Quill/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `Meeting Audio.m4a` | the meeting as one playable file |
| `Source Audio/Microphone.m4a` | your side (default input device, AAC) |
| `Source Audio/Call.m4a` | everything the Mac played - the other side of the call (AAC) |
| `Source Audio/Microphone Cleaned.m4a` | microphone audio with correlated speaker playback removed (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets, and per-track capture health |
| `session.log` | devices, formats and every capture interruption during the recording |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two source tracks on purpose: speech models do better on clean single-source
audio, and microphone-vs-call gives useful separation without a
speaker-identification model. Quill records AAC into CAF while capture is live,
so audio already written survives an interruption, then safely remuxes it into
familiar M4A files after stop. An interrupted session is recovered on launch.

macOS changes audio devices out from under a live recording — a headset
connecting takes the default input and output at once, and switching Bluetooth
off stops the system tap dead. Both tracks are rebuilt on the new device and the
outage is padded with silence, so the two tracks keep describing one timeline.
Each track's `tracks.<name>` entry in `meta.json` carries `duration_seconds`
against `captured_seconds` and the gaps between them; `session.log` says what
happened.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port, roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download after the first unmetered launch; progress appears in the
menu and Settings. `quill doctor` reports whether they are ready.

Before publishing the finished files, WebRTC AEC3 uses the call track as a
reference to remove correlated speaker playback from the microphone. The
result is retained as `Source Audio/Microphone Cleaned.m4a`; both original
source tracks remain unchanged. If cancellation fails, the failure is logged
and transcription falls back to the original microphone track.

The cleaned microphone and raw system tracks are transcribed separately,
shifted by their start offsets so both share one clock, and merged by
timestamp. Jobs run in a serial queue — you can start a new recording while
the last one transcribes. Unfinished jobs resume on next launch (the filesystem
is the queue: a session with `meta.json` but no `transcript.json` is pending).
Failures append to the session's `transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

At `~/Library/Application Support/Quill/config.json`:

```json
{
  "recordings_dir": "~/Music/Quill",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "audio_retention": "indefinitely",
  "on_stop": "my-hook"
}
```

The menu and Settings window write to this same file. Hand-edited keys such as
`on_stop` are preserved when a UI setting changes. `QUILL_HOME` overrides the
application home for isolated development and tests.

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  the folder picked in Settings > config > `~/Music/Quill`.

  The default avoids `~/Documents`, `~/Desktop` and `~/Downloads` on purpose.
  Those are TCC-protected, and a menu-bar app has no window for macOS to hang
  the permission prompt on, so access is denied silently: the folder stays
  writable while listing it returns nothing. If you want quill to save there
  anyway, use **Change…** beside the folder in Settings rather than setting it
  here. Choosing through the open panel is what grants access. If access later
  breaks, **Change Recordings Folder…** also appears in the menu as recovery.
- `transcription.enabled` — set `false` to just record.
- `audio_retention`: `indefinitely` (the default), `30_days`, or
  `after_transcription`. Deletion only applies after `transcript.json` exists.
  It removes `Source Audio/` but retains `Meeting Audio.m4a`. The transcript
  cannot then be reprocessed and voice samples are unavailable.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Music/Quill)
quill doctor                 # check permissions, recordings folder, models
quill watch-calls            # print recognized call-input transitions
quill watch-calls --all      # also print unknown microphone users
quill install --launch-at-login   # same as Settings → Open at login
quill install --uninstall
```

`watch-calls` is an observation-only test harness over the same Core Audio
scanner and stable-transition reducer used by the menu app. It prints snapshots
and possible call transitions, but never shows notifications or affects a
recording. The menu app writes its own snapshots to
`~/Library/Application Support/Quill/cache/call-detection.log`.

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **WebRTC AEC3** — post-recording acoustic echo cancellation
- **NSStatusItem + AppKit**: menu-bar controls and a small Settings window

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a login item.
