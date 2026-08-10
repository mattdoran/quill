# TODO

Working backlog. Notes marked **now** are the current state, not a decision.

## Packaging and install

- [ ] **Auto-register for launch at login.**
      *Now:* not automatic. `quill install --launch-at-login` writes a
      LaunchAgent plist by hand. Nothing happens unless you run it.
      Since there is a real bundle, `SMAppService` is available and would put
      quill in System Settings → Login Items where it can be toggled without
      the CLI.
- [ ] **Register at login on first run, on by default.** *Decided.* A menu-bar
      recorder that has to be started by hand is one you forget before the
      meeting that mattered. macOS now announces background registration
      itself and puts a toggle in Login Items, so it is visible and one click
      to undo without a prompt of our own.
      Still needs a menu item reflecting and toggling the current state, so it
      is discoverable without going to System Settings.
- [ ] **Onboarding, later.** First run could explain the two tracks, trigger
      the permission prompts deliberately rather than mid-meeting, kick off the
      model download, and confirm launch-at-login. Not now.
- [ ] **Do not require /Applications.**
      *Now:* not required. `~/Applications` works, and so does anywhere else;
      `Install.swift` looks in both. Only the LaunchAgent needs a stable path.
- [ ] **Ship a DMG.** Background image with an arrow, `/Applications` symlink,
      volume icon, window size and icon positions set. `create-dmg` does this,
      or `hdiutil` plus an AppleScript for the window layout. Needs artwork.

## Configuration

- [ ] **Config UI.** Trigger for building one: the moment a setting cannot be
      explained in a menu item's title. Speaker detection already needed two
      lines of explanation each.
- [ ] **Config location.**
      *Now:* `~/.config/quill/config.json`, plus `State` for menu toggles.
      Tension to resolve: XDG-style is right for a CLI tool, but this is now a
      signed app with a bundle identifier, where macOS convention is
      `~/Library/Application Support/Quill/`. Pick one home and put config,
      state and any cache under it.

## Recordings

- [ ] **Keep or discard the audio after transcription.** Needs design, not just
      a flag:
      - What is the default? Discarding is the privacy-respecting answer;
        keeping is the recoverable one.
      - If keeping, what format? The tracks are AAC in CAF now. WAV is lossless
        but roughly 10x larger; re-encoding to MP3 or AAC-in-M4A is smaller and
        universally playable.
      - One file or two? Merging mic and system into left/right channels keeps
        both sides recoverable and halves the file count, but a stereo file is
        misleading if anyone plays it expecting stereo audio.
      - Mono merge loses the ability to tell who spoke, which is the thing the
        two-track design exists to preserve.
      - Retention window rather than a boolean: keep for N days, then drop.

## Models

- [ ] **Fetch models before someone needs them.**
      *Now:* `AsrModels.downloadAndLoad` runs inside the first transcription,
      so the first meeting after install pays ~600 MB of download before any
      text appears. The diarizer adds a second model on top.
      `Doctor.swift:90` already knows how to test the cache without
      downloading, so the check exists; only the prefetch is missing.
      Design points: trigger on first launch or from the menu, not silently on
      a metered connection; leave it resumable, because a half-download must
      not look like a cached one.

- [ ] **Show download progress.** 600 MB is minutes on an ordinary connection
      and forever on a bad one, and right now it is indistinguishable from a
      hang.
      *Available:* `ModelHub.download(_:to:variant:additionalModelNames:
      progressHandler:)` takes a `@Sendable (DownloadProgress) -> Void`, where
      `DownloadProgress` carries `fractionCompleted` and a `phase`. The
      `AsrModels.downloadAndLoad` convenience quill calls today discards it,
      so switching to `ModelHub.download` then loading from cache is what
      exposes it.
      The menu already has a status line for transcription progress
      (`updateTranscription`), so there is somewhere to put it without new UI.

## Detection quality

- [ ] **The silence nudge measures level, not voice.** RMS above -50 dBFS
      counts as somebody being there, so a fan, street noise, a keyboard or
      music all reset the ten minutes. The failure mode is safe — it stays
      quiet rather than nagging — but in a noisy room the nudge will never
      fire, which is exactly the room where you forget to stop.
      *Available:* FluidAudio already ships Silero VAD (`VadManager`, 16 kHz,
      4096-sample chunks, `VadResult.isVoiceActive` plus a probability).
      Cost: a third model to download, and continuous inference on live audio
      for the whole meeting rather than a `max()` over samples.
      Decide whether that trade is worth it before building it. A cheaper
      middle option is a higher threshold plus requiring the level to *vary*,
      since steady noise has far less variance than speech.

## Licensing

- [ ] **Bundle the licences with the app.** Apache 2.0 (FluidAudio,
      swift-argument-parser) requires the licence text to travel with
      distributed binaries. MIT requires upstream's notice to travel too.
      Collect all three into `Contents/Resources/`, and into the DMG once there
      is one.
- [ ] **Add my own copyright line.** Alongside `Copyright (c) 2026 Andrew
      Jones`, not replacing it, covering the changes in this fork.

## UI

From an independent review of the menu-bar surface. Ordered worst first.

### Wrong, not just unpolished

- [ ] **Trouble never clears.** `reported` is insert-only, so a 4s blip at
      minute 2 leaves the icon yellow for the rest of the meeting, claiming
      something is wrong when nothing is. Split live state (`isDegraded`,
      clears on recovery, drives the icon) from the incident list (sticky,
      drives the menu line).
- [ ] **"Transcribing X" is a lie during the model download.** `.transcribing`
      is published before `preparedEngine()` runs, so a 600 MB first-run
      download reads as transcribing for minutes. Publish a `.preparing` state
      first: "Preparing transcription model…".
- [ ] **Cmd-R and Cmd-O do not work.** Menu key equivalents only fire while the
      menu is open, so advertising them promises a shortcut that does not
      exist from inside Zoom. Remove them, or add a real global hotkey.
- [ ] **Session folder names shown to humans.** "transcribing 2026.08.10-1432"
      is a filesystem identifier. Format as "Transcribing 2:32 PM recording".
- [ ] **Status item position is not remembered.** Set
      `statusItem.autosaveName`. One line.
- [ ] **Notification permission asked at login**, before the user has done
      anything, and worst when launched by the LaunchAgent. Ask on first stop
      instead, seconds before the first notification fires.
- [ ] **State-by-colour only.** Red vs yellow at 16pt is one state to a
      deuteranope, and VoiceOver reads a nameless image plus a number. Change
      the glyph, not just the tint, and set an accessibility title.

### Wording

- [ ] **"Detect speakers" reads as loudspeakers** on an audio app. Proposed:
      "Separate Voices in the Room (Mic)" and "Separate Voices on the Call
      (System Audio)". Add tooltips naming the second model download.
- [ ] **Title case on commands, and "Quit Quill" not "Quit quill".**
- [ ] **Use `NSMenuItem.toolTip`.** Currently unused everywhere. It is the
      thing that lets settings stay in the menu instead of needing a window.

### Missing

- [ ] **Open Last Transcript.** The app's whole output is three steps away once
      the notification is gone.
- [ ] **Cmd-Q silently ends a live recording.** Retitle to "Stop Recording and
      Quit" while recording.
- [ ] **Retry a failed transcription.** Today the documented recovery is quit
      and relaunch so `resumePending` picks it up.
- [ ] **About box and version.** `Info.plist` has no
      `CFBundleShortVersionString`; Get Info shows blank.
- [ ] **"Open at Login" toggle**, via `SMAppService`, replacing
      `install --launch-at-login`.

### Decide

- [ ] **Should an unrecovered track interrupt?** The review's top finding is
      that a dead mic is announced only by a hue change, so a meeting can be
      lost in silence. That argues for one notification when a track is still
      down, which is the design deliberately removed for being noisy. The
      narrow version: notify once per session, only when a track has not
      recovered, never on a blip that healed.
- [ ] **Settings window: not yet.** Everything current fits in the menu with
      tooltips. Build one when model-download progress and audio retention
      land, since neither fits a menu item.

## Repo hygiene

- [ ] **Branch name no longer describes the work.** `feat/detect-speakers`
      carries capture resilience, packaging, signing and notification changes.
- [ ] **Decide fork vs upstream.** Capture resilience is generic and would
      apply to anyone's quill. Bundling, signing, icon and DMG are specific to
      this fork. Worth keeping the first separable if upstream is ever in play.
