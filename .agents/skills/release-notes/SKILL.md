---
name: release-notes
description: Writing or revising Quill's release notes in docs/release-notes/<version>.md. An independent agent drafts them in the user's voice from a list of user-visible facts, a fresh agent reviews them adversarially, and Matt approves the text before it is published. Use when preparing a release, before `./release.sh check`, or when published notes need rewriting.
---

# Release notes

Users read these in Sparkle's update window and on the GitHub Release page.
The author of the changes writes in the terms of the code, so the notes are
drafted and attacked by agents that see only what a user would notice.

## The voice

Matt rejected drafts on 2026-10-26 for each of these:

- **Say what the user sees and does, never how it works.** "Quill asks VBx for
  one more cluster" and "the count is an estimate" were gobbledegook.
- **Lead with the benefit when there is one.** "More accurate. You may see one
  extra voice."
- **One short line per bullet.** A bullet with a reason attached is too wordy.
- **No explanations, contrasts or justifications.** "Rather than merging two
  people into one" confused; "that is deliberate" sounded defensive.
- **Use the app's exact labels.** Head a section with the feature's own label
  (`Separate Voices`, not "Separating voices"), bold buttons, quote prompts.
- **Say when the user has to act.** "Give both the same name and save."
- **Claim only what is true and new.** "Google Meet" implied Meet was never
  detected when only the web app was new. "No longer disappears on its own"
  was false: the prompt still closes when the call ends.
- **Leave out what a user cannot notice:** tests, builds, signing, install
  scripts, internal refactors.
- Australian English. No em-dashes.

## Process

1. **List the facts.** From `git log <previous tag>..HEAD`, write one plain
   fact per user-visible change: what the user now sees or does, the exact UI
   labels (check them in the source), what existed before, and anything that
   stays true. The last two are what let a reviewer catch an over-promise.
   Leave out commit messages and design reasoning.
2. **Independent draft.** Start a new agent with the drafter prompt below,
   filled in. It gets only the facts and the previous release's notes.
3. **Adversarial review.** Start another new agent, never the drafter and
   never a resumed reviewer, with the reviewer prompt below. Never brief it to
   check accuracy only or to avoid lengthening: that review let a confusing
   line through. `{ref}` is `HEAD` for a release, or the tag when rewriting
   published notes; a reviewer left to the current branch renamed old notes to
   the next version and checked labels against later code.
4. **Revise** with its findings. If it found an inaccuracy, or the text
   changed beyond wording, review the result with one more new agent.
5. **Show Matt the final text** with what each review changed, and wait for
   his approval. Then write `docs/release-notes/<version>.md`.

`./release.sh publish` copies the file into the GitHub Release body, adds the
changelog link, and embeds that body in the appcast. To change notes after
publishing: edit the file, run `gh release edit <tag> --notes-file` with the
file plus the same changelog line, replace that version's `<description>`
CDATA in `docs/updates/appcast.xml` with `gh release view <tag> --json body
--jq .body`, check it with `xmllint --noout`, then commit and push. GitHub
Pages serves the feed about a minute later.

## Drafter prompt

```text
Write the release notes for Quill {version}, a macOS menu-bar app that records
meetings and makes transcripts. They appear in the app's update window and on
GitHub. Write in the user's voice: what a user sees and does, in a user's words.

Rules:
- Say what changed for the user, never how it works or why it was built that way.
- Lead an item with its benefit if it has one, for example "More accurate."
- One short line per bullet. At most two sections of two or three bullets.
- Use the exact labels given in the facts. Bold buttons, quote prompts, and head
  a section about one feature with that feature's label.
- No explanations, contrasts or justifications: no "rather than", "instead of",
  "because", "that is deliberate".
- Say when the user has to do something, for example save.
- Claim nothing the facts do not support. Name only what is new.
- Plain Australian English. No em-dashes.

Facts, your only source:
{facts}

The previous release's notes, for tone:
{previous notes}

Reply with the Markdown only, starting with "## Quill {version}".
```

## Reviewer prompt

```text
Review release notes before they reach Quill's users. Be adversarial: treat
each line as confusing, wordy or wrong until it proves otherwise. The owner has
rejected notes for jargon, wordiness, clauses that explain or justify a change,
missing the change that matters most, and claims that were not true. Judge
clarity and brevity as hard as accuracy.

Readers are everyday users of a macOS meeting recorder. They know its windows
and buttons, nothing about how it works.

These are the notes for Quill {version}: keep that version. If you check a
label in the code, check it at {ref}, the commit being released, not the
current branch.

Facts the notes must match:
{facts}

The draft:
{draft}

For each line ask:
1. Would a user understand it on first read?
2. Could it be shorter without losing what the user needs?
3. Is anything untrue, over-promised or vague?
4. Does it say what the user must do, and when?
5. Do button and prompt names match the facts exactly?
6. Does it explain, justify or contrast instead of saying what changed?

Reply with one short sentence per problem, then your final version. It must be
no longer than the draft and accurate to the facts. Under 200 words.
```
