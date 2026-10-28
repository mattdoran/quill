# TODO

Work that remains. Product and architecture decisions live in
`docs/decisions.md`; the UI specification lives in `docs/ux.md`.

## Verification

- [ ] **Review the installed menu and Settings window visually.** Both build and
      launch, but the status item is not exposed to the available UI automation.
- [ ] **Measure mute and device switching in a real browser meeting.** Safari
      and Chrome Meet detection passed on 2026-08-19; dismissing Chrome's start
      prompt correctly produced neither recording nor an end prompt.

## Transcription

- [x] **Clear stale voice-memory keys on re-separation.** Separating a track
      again forgets that track's contributions for the meeting, `Not the Same
      Person` removes only from the voice's own profile, and two profiles of
      one name no longer block each other's suggestion. The two stale
      contributions from 2026.10.13-1231 were removed by hand on 2026-10-28,
      backed up beside `voice-profiles.json`.
- [ ] **Next: guard against echo, then find why echo cancellation failed on 26
      October.** On built-in speakers and microphone, 22% of local segments
      repeated remote speech (49.5% of local words), against 1% or less in every
      other meeting. The microphone sat near -60 dBFS, against -18 to -32
      usually, it changed format twice in the first six seconds, and live AEC
      attenuated only 1 to 4 dB. Echo lagged the call by 0.85 s there, against
      0.10 to 0.15 s elsewhere, and it is the only session with recorded
      microphone gaps, which suggests a misaligned timeline (unverified). Flag
      local rows that repeat a remote row within 3 s, and log the echo delay
      from the two tracks' loudness.
- [ ] **Add a per-meeting "needs review" check.** After every recording: echo
      rate from the text (flag above 10%) and echo delay (flag outside 0 to
      0.3 s). After separation: per-row margin from FluidAudio's chunk
      embeddings (`exposeChunkEmbeddings`), flagging a track with over 5% of
      rows under 0.2; a leftover voice under 5% of the track and 0.6 similar to
      two others; the `Unassigned` word share. Optional fields in
      `transcript.json`. Echo checks first. Margin under 0.2 flagged 6.6% of
      rows and caught 42% of disagreements across 18 tracks.
- [ ] **Log name edits and keep diarization evidence.** Record each naming
      action (voice, old name, new name, suggestion shown or accepted), and
      keep the diarizer spans and per-row margins. Names are overwritten today,
      so there is no labelled data beyond the one hand-labelled 27 August call.
- [ ] **Keep Parakeet word timings in `transcript.json`.** They are discarded
      after rows are formed, so no later stage can split a row at a speaker
      change. Size growth is not yet measured.
- [ ] **Lower the voice-memory suggestion threshold to about 0.72.** The same
      person on microphone and on a call scored 0.763 to 0.786, under 0.82;
      different people never exceeded 0.627 across 448 pairs. Only 34 voices
      back this, so check it against the name-edit log once it exists.
- [x] **Group transcript rows into speaker turns at render time.** One derived
      turn model on `TranscriptDocument`, used by the review window,
      `transcript.md` and Copy Markdown; `transcript.json` keeps its sentence
      rows, which separation, repeat and undo depend on. 73% of rows are
      followed by the same speaker, and grouping leaves 73% fewer blocks across
      31 meetings. Short replies ("yeah", "mm-hmm") said inside another
      person's turn show inline as `[Matt: yeah]`, in the window and the
      Markdown. A short reply is a segment whose whole text, ignoring case and
      punctuation, is on a fixed list of 64 phrases ("no" included), never a
      word count; fillers (um, uh, er) are hidden on the same whole-segment
      rule. The list is `TranscriptTurns.replies`. Unassigned
      bits of 5 words or fewer inside one person's turn join that person's
      words, marked in the window as a guess. A reply to a question stays its
      own turn when the asker's row ends with "?". The Markdown's title becomes
      the meeting's date and time (`SessionName.dated`), not the folder id,
      followed by one line with the duration and the people by speaking time;
      this revises the 2026-08-20 consequence that the Markdown holds only
      title and transcript. The window and the Markdown each show one time per
      turn. A new paragraph starts at a sentence end after 1.5 s of
      silence, or once a paragraph reaches 120 words with at least 40 words of
      the turn left. It never breaks before a row that starts lowercase, so
      interjections can't split a sentence. The silence is anyone's: speech
      by anyone, including a reply shown inline or hidden, ends it, so another
      person's "yeah" can't break the speaker's paragraph. The playground
      (https://uncle-emit-57.artefacts.page/, expires 2026-11-25) runs these
      rules on real meetings. Build Play from Here with it: clicking a turn's
      time plays `Meeting Audio.m4a` from that point, which survives
      retention. Rewrite existing `transcript.md` files only where they still
      exactly match the old renderer's output, so hand-edited files are left
      alone.
- [ ] **Add a meeting name to transcript review.** A `Meeting name` field at
      the top of review, saved in `meta.json`. The Markdown title uses it when
      set, otherwise the date and time; the date stays in the header line. The
      folder name stays a timestamp. Calendar prefill waits on the calendar
      question in `docs/open-questions.md`.
- [ ] **Add Send to Shortcut to transcript review.** A Settings picker chooses
      one Apple Shortcut (None, or the list from `shortcuts list`); when set,
      the review footer shows `Send to <name>` beside Copy Markdown. It saves
      pending names, then runs `shortcuts run <name> --input-path
      transcript.md`; a failure shows an alert with the Shortcuts error. It is
      disabled during separation, like Copy Markdown. The shortcut decides
      what happens next: an AI service, a web address, a folder, a note or
      mail. Build after turn grouping, since it hands over the new Markdown.
- [ ] **Mark doubtful rows in review**, after transcript turns are grouped,
      using the per-row margin from the review check.
- [ ] **Add WhisperKit large-v3-turbo as a fallback and re-transcription
      option.** Parakeet remains the fast English default. Re-transcription is
      one reason source audio is retained by default.
- [ ] **Attribute short replies after separation.** FluidAudio drops every
      speaker span under its 1-second `minSegmentDuration`, so 58% of 1,037
      `Unassigned` segments across 18 meetings were under a second and 45% a
      lone "yeah", "yep" or "okay". A 0.3-second minimum cut unassigned speech
      from 1.9% to 0.7% but lowered accuracy on short named lines from 96.7% to
      94.8%; 0.5 seconds is untested. The nearest span's voice was right only
      39 to 51% of the time, so it is not a fallback.

## Controls

- [ ] **Add a real global recording hotkey.** Menu key equivalents fire only
      while the menu is open and must not be presented as global controls.

## Command line for assistants

Settled 2026-10-28 in `docs/decisions.md`.

- [x] **Add reading commands and the assistant skill.** `quill status`,
      `quill list [--since 7d]` and `quill show <meeting>`, each with
      `--json`, read the files and need no running app. A meeting id is its
      folder name, or `latest`. Developer tools moved under `quill dev`.
      `quill skill install` links the skill bundled in Quill.app for
      assistants.
- [ ] **Add a channel to the running app, then `quill name`.**
      `quill name <meeting> "Voice 2=Will"` asks the app, launching it when
      needed, so an open review window shows the names and voice memory
      applies. A socket under `QUILL_HOME` is the candidate channel; `separate`,
      `import` and `record` reuse it.
- [ ] **Add `quill separate <meeting> [--local N] [--remote N]` and
      `quill record start|stop`** over the same channel.

## End-to-end meeting workflow

- [x] **Build the meeting companion as one stateful surface.** Prove detected,
      recording, recovered-end, stopping, short processing and ready states.
      Verify non-activation, full-screen Spaces, multiple displays and
      VoiceOver before replacing native call prompts.
- [x] **Move speaker separation into transcript review.** Recording and initial
      transcription have no meeting profile. Optional review diarises both
      retained source tracks without rerunning speech recognition.
- [x] **Finish stopped recordings as M4A.** Prove packet-preserving
      CAF-to-M4A conversion with Apple media APIs. Publish `Meeting Audio.m4a`
      plus separate source tracks only after duration verification, update
      metadata atomically, and recover unfinished CAF sessions at launch.
- [x] **Add focused voice identification after transcript generation.** Rank
      representative source-audio samples, let a person name a stable voice ID,
      and apply that label across its cluster without becoming a general
      transcript editor.
- [x] **Unify transcript completion and review.** Keep processing visible until
      dismissal or completion, then route both companion and native notification
      actions into one read-only transcript and speaker review window.
- [x] **Choose earlier meetings from a list, not a folder.** `Meetings…`
      replaces three menu items with a chooser listing meetings by date,
      length, people and state; `Review Last Transcript…` stays.
- [ ] **Import recordings as meetings (deferred, raised 2026-10-28).** For
      in-person meetings Matt often records in Voice Memos on his phone
      instead of starting Quill, so those meetings get no transcript, names or
      folder for the admin hub's harvest of `~/Music/Quill`. An import of a
      memo or any other audio file should end as a normal session, as if Quill
      had recorded it: a folder named from when the audio was recorded,
      `transcript.md` in the usual format, and the same speaker naming and
      voice memory. `quill import <audio>... [--at <time>]` does the same
      ingest through the running app, so an agent can import a file without
      the UI; it follows `quill name`. Voice Memos keeps
      synced recordings in
      `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`,
      with titles and dates in `CloudRecordings.db`; treat it as read-only. A
      memo is one mixed track, not separate mic and system tracks. Design
      questions first, with a proposal before building:
      - How it is triggered in the app: Quill noticing new memos and offering
        them, a menu item, or drag and drop. Least fiddly wins. The CLI
        command is wanted either way.
      - Where an arbitrary file's recording time comes from when it has no
        Voice Memos entry.
      - How memos are chosen, and whether several from one visit become one
        meeting (the 2026-10-28 E&S Trading visit was three: 10:55, 11:10 and
        11:16).
      - How a single mixed track maps onto the session layout and
        separation, which assume Local and Remote sources.
      That visit was done by hand with `quill diarize --num-speakers 2` on each
      memo and a stitched Markdown file, in
      `~/projects/claude-scratch/20261028-124939-screenshot-2026-10-28-12-49-14-2x/transcript.md`.

## Permissions

- [ ] **Ask for permissions deliberately, not on first record.** Today the
      microphone and system-audio prompts fire during the first recording, and a
      denial surfaces only as an `OSStatus` in `tapCreationFailed`. Both grants
      should be requested from an explicit Enable control in Settings, and a
      refusal should deep-link to its own pane:
      `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`
      for the tap and `?Privacy_Microphone` for the microphone.
      `Privacy_AudioCapture` is the anchor that matches `kTCCServiceAudioCapture`
      and lands on the "System Audio Recording Only" list, which is where Quill
      is granted. `Privacy_ScreenCapture` is a different anchor for a permission
      Quill does not use.

      The microphone side is easy: `AVCaptureDevice.authorizationStatus(for:
      .audio)` reads the state without prompting.

      The tap side has no public equivalent. It is gated by
      `kTCCServiceAudioCapture`, confirmed in the TCC database, and no framework
      exposes a prompt-free check for it. Granola reads it through the private
      `TCCAccessPreflight` in TCC.framework. The alternative is to build a tap
      and wait for one buffer, which is the request itself, so checking and
      asking collapse into the same action. Decide which before building the
      Settings UI, since a status display needs the check to be separable.
