---
name: quill
description: Read the user's recorded meetings with Quill, the meeting recorder on this Mac. Use when asked about a meeting or call, what someone said in one, its transcript, who attended, or whether a recording is still being transcribed.
---

# Quill

Quill records the user's meetings on this Mac and transcribes them on-device.
Each meeting is a folder in the recordings folder, `~/Music/Quill` unless the
user chose another in Quill's Settings; `quill status` prints where it is.
Read meetings through the `quill` command rather than the folder, whose layout
is internal and changes.

## Find a meeting

`quill list --since 7d --json` lists meetings, newest first. Each has an `id`,
a `title` (its date and time), `started`, `duration_seconds`, `people` by
speaking time, a `state`, and `transcript`, the path of its Markdown. Pick
the meeting by date and people; if two fit, ask the user which.

## Read it

`quill show <id>` prints the transcript as Markdown, and `quill show latest`
prints the newest meeting's. `quill show <id> --json` adds `voices` and
`turns`, each turn with `start_ms` from the start of the recording.

In a transcript:

- `**Will** (12:04):` starts Will's turn, 12 minutes 4 seconds in.
- `[Matt: yeah]` is a short reply by Matt inside someone else's turn.
- `Unassigned` is speech Quill could not attribute to anyone.
- `Voice 2` and similar labels are people nobody has named yet. Don't present
  a guess about who they are as fact.

## Check progress

`quill status --json` gives the recordings folder, says whether Quill is
running, and lists meetings that are recording, finishing their audio,
transcribing, or from the last 7 days waiting for names. A meeting has no
transcript until it leaves `transcribing`; until then `quill show` exits with
status 2.

Run `quill <command> --help` for every option.
