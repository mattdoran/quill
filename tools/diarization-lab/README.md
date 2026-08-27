# Quill diarization lab

Local diagnostic viewer for comparing diarizer spans with a retained Quill
transcript and recording human speaker labels. It reads a session but never
writes into it.

Run it from this directory:

```sh
./run-dev ~/Music/Quill/2026.08.27-1231 \
  --run sortformer=/path/to/sortformer.json \
  --run vbx=/path/to/vbx.json
```

Then open the printed localhost address. Model runs may use either FluidAudio's
Sortformer/LS-EEND JSON schema (`speakerIndex`) or offline VBx schema
(`speakerId`).

Human labels are saved atomically beneath
`devdata/data/annotations/<remote-audio-sha256>.json`. Derived caches belong
beneath `devdata/cache/` and may be deleted.

After any A, B or C labels are saved, each model summary reports row and
duration accuracy under its best one-to-one mapping from anonymous model slots
to human speakers. `Mixed` and `Unclear` rows are excluded. An extra model slot
cannot share a human identity with another slot, so splitting one person is
penalized rather than hidden.
