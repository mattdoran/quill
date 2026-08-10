# TODO

Working backlog: what is not done. The design of the UI itself lives in
`docs/ux.md`, which is largely built.

## Packaging and install

- [x] **Launch at login via `SMAppService`**, with an Open at Login menu item
      that reads the system's status rather than remembering its own.
- [ ] **Turn it on by default for a new install.** *Decided, not built.* The
      toggle exists but nothing enables it on first run, so a fresh install
      still has to be told. A menu-bar recorder you have to remember to start
      is one you forget before the meeting that mattered.
- [ ] **Onboarding, later.** First run could explain the two tracks, trigger
      the permission prompts deliberately rather than mid-meeting, kick off the
      model download, and confirm launch-at-login. Not now.
- [x] **Do not require /Applications.** `~/Applications` works, and
      `Install.swift` looks in both. Note that `SMAppService` ties startup to
      wherever the app sits, so moving it after enabling breaks startup until
      the toggle is flipped again.
- [ ] **Ship a DMG.** Background image with an arrow, `/Applications` symlink,
      volume icon, window size and icon positions set. `create-dmg` does this,
      or `hdiutil` plus an AppleScript for the window layout. Needs artwork.

## Configuration

- [ ] **Config UI.** Not yet: everything current fits a menu item plus a
      tooltip. `docs/ux.md` fixes the trigger for building one, and audio
      retention is the item most likely to trip it.
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

- [x] **Fetch models before someone needs them.**
      *Now:* `AsrModels.downloadAndLoad` runs inside the first transcription,
      so the first meeting after install pays ~600 MB of download before any
      text appears. The diarizer adds a second model on top.
      `Doctor.swift:90` already knows how to test the cache without
      downloading, so the check exists; only the prefetch is missing.
      Design points: trigger on first launch or from the menu, not silently on
      a metered connection; leave it resumable, because a half-download must
      not look like a cached one.

- [x] **Show download progress.** 600 MB is minutes on an ordinary connection
      and forever on a bad one, and right now it is indistinguishable from a
      hang.
      *Done.* `AsrModels.download(to:force:version:encoderPrecision:
      progressHandler:)` reports `fractionCompleted`, and resolves its own
      cache directory, so a prefetch cannot land the files where the loader
      will not look.

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

## About and versioning

- [ ] **Short commit hash and build date in the version**, tastefully. `About`
      currently shows `0.1` and nothing else, and `CFBundleVersion` is hardcoded
      to `1`, so two builds a week apart are indistinguishable.
      Shape: `bundle.sh` stamps `CFBundleVersion` as the short hash and a
      build date at assembly time, leaving `CFBundleShortVersionString` as the
      human version. The About panel then reads `0.1 (a1b2c3d, 10 Aug 2026)`.
      Do not commit the stamped plist — generate it into the bundle.
- [x] **Acknowledgements in About?** Not required. Apache 2.0's attribution
      clause applies only where a `NOTICE` file exists, and neither dependency
      has one; shipping the licence text in `Contents/Resources/Licenses`
      satisfies it. The standard About panel takes a credits attachment if it
      is ever wanted for its own sake.

## Licensing

- [x] **Bundle the licences with the app.** All three ship in
      `Contents/Resources/Licenses`. They need to go into the DMG too, once
      there is one.
- [x] **Add my own copyright line**, alongside Andrew's rather than replacing
      it.


## Repo hygiene

- [x] **Branch merged to master.** Upstream is not in play, so this is the
      trunk rather than a feature branch off someone else's.
- [ ] **Notarize the build that gets shared.** Notarization applies to one
      exact binary, so it is worth doing on whatever is handed over rather
      than on every commit. `./bundle.sh --notarize`.
