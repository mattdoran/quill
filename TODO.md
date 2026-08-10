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

## Licensing

- [ ] **Bundle the licences with the app.** Apache 2.0 (FluidAudio,
      swift-argument-parser) requires the licence text to travel with
      distributed binaries. MIT requires upstream's notice to travel too.
      Collect all three into `Contents/Resources/`, and into the DMG once there
      is one.
- [ ] **Add my own copyright line.** Alongside `Copyright (c) 2026 Andrew
      Jones`, not replacing it, covering the changes in this fork.

## Repo hygiene

- [ ] **Branch name no longer describes the work.** `feat/detect-speakers`
      carries capture resilience, packaging, signing and notification changes.
- [ ] **Decide fork vs upstream.** Capture resilience is generic and would
      apply to anyone's quill. Bundling, signing, icon and DMG are specific to
      this fork. Worth keeping the first separable if upstream is ever in play.
