# 2026-08-27 diarization investigation

Session `2026.08.27-1231` was a 50:43 remote call with three known remote
speakers and one local speaker. The remote participants were one man and two
women with distinct voices. The user ran speaker separation, saw identities
mixed together, then used Undo Voice Separation. The canonical transcript is
therefore the original two-source transcript, as expected.

## Outcome

The primary failure is the diarization model mode, not Quill's audio capture or
its transcript assignment step. Quill uses FluidAudio's
`OfflineSortformerDiarizer`. That implementation runs independent fixed
30.72-second windows without the streaming model's speaker cache or FIFO state.
It joins windows by overlapping activity, not by a persistent acoustic voice
identity. FluidAudio documents this path for short or few-speaker audio and
reports about 56% DER on AMI-SDM, compared with about 26% for high-context
stateful Sortformer.

The observed result reproduces that documented limitation. Offline Sortformer
returned four slots for the three-speaker remote track. Compared with the
whole-file VBx acoustic clusters, every slot contained material speech from all
three clusters. Quill's dominant-overlap assignment adds some row-level
ambiguity, but it receives already-confused identities and is not the principal
cause.

Stateful high-context Sortformer and whole-file VBx are both credible next
candidates. The first retained three strong identities but used a short fourth
slot that appears to split one person. VBx returned three coherent clusters
when told the known count, but its automatic bounded run selected four. Human
labels are required to choose between them and to measure the cost of the extra
slot honestly.

## Capture and file checks

Quill ran the installed `0.4.0-dev` build 4. System capture started at 12:31:53
and stopped at 13:22:37. The session log records no system-track gaps. It records
one microphone route gap at stop, outside the meeting content.

All four published artifacts are mono 48 kHz AAC and decode completely:

| Artifact | Size | Duration | Mean / peak |
|---|---:|---:|---:|
| Remote | 21.9 MB | 3043.6 s | -25.7 / +0.06 dBFS |
| Local | 23.7 MB | 3043.6 s | -51.3 / -19.7 dBFS |
| Local Cleaned | 22.8 MB | 3043.6 s | -65.4 / -25.4 dBFS |
| Meeting Audio | 23.9 MB | 3043.6 s | -28.8 / -3.0 dBFS |

Remote contains one absolute peak sample among 146,092,992 decoded samples and
has no flat-topped clipping. The level is not evidence of a damaged track.

The macOS unified log contains one `IOWorkLoop: skipping cycle due to overload`
entry at 12:42:10. Quill's persisted timeline records no corresponding system
gap, and the file decodes across that point. Core Audio errors clustered at
startup and stop are accompanied by successful engine setup and completed file
exports. They do not line up with the sustained identity mixing.

## Transcript and assignment checks

Parakeet produced 725 rows in 22.9 seconds: 484 remote and 241 microphone. The
remote rows are comparatively long: median 3.04 seconds, 90th percentile 12.0
seconds, and maximum 22.96 seconds. Sixty-two remote rows exceed ten seconds.
Long rows can contain speaker turns, so any single-label dominant-overlap policy
will lose some boundaries.

For the reproduced current run, 58 of 484 remote rows overlap a second model
speaker for at least 0.5 seconds, and 69 have less than 80% dominant-speaker
purity. This is a real secondary problem. It does not explain the identity
failure because the raw model slots themselves mix the acoustic clusters.

## Model experiments

Every experiment used the exact retained `Remote.m4a`. FluidAudio 0.15.5 from
Quill's resolved dependency performed all inference locally.

| Run | Time | Peak memory | Raw spans | Slots | Assignment shape |
|---|---:|---:|---:|---:|---|
| Offline Sortformer v2.1, current | 28.6 s | 1.93 GB | 675 | 4 | All four slots mix all three VBx clusters |
| Stateful Sortformer high-context | 35.9 s | 1.60 GB | 578 | 4 | Three main slots agree 89%, 95%, 94% with VBx; one short duplicate slot |
| Offline VBx, known count 3 | 24.2 s | 0.61 GB | 456 | 3 | Three whole-file acoustic clusters |
| Offline VBx, bounded 1 to 4 | 27.1 s | 0.61 GB | 464 | 4 | Three coherent clusters plus a small mixed cluster |
| LS-EEND AMI, 500 ms | 35.0 s | 1.41 GB | 1185 | 4 | Fragmented; dominant slot mixes all three VBx clusters |

The VBx comparison is a pseudo-reference, not ground truth. Its value is that
it provides an independent, whole-file acoustic clustering method. The current
offline Sortformer has no clean mapping to it:

| Offline slot | Largest VBx cluster | Second | Third |
|---|---:|---:|---:|
| 0 | 56% | 27% | 17% |
| 1 | 53% | 29% | 19% |
| 2 | 65% | 32% | 3% |
| 3 | 79% | 13% | 8% |

Stateful Sortformer has a materially different structure. Its main slots map
to one VBx cluster at 89%, 95% and 94%. The remaining slot contains about 61
seconds and agrees 69% with the cluster already represented by the 95% slot.
This suggests a speaker split, subject to human confirmation.

VBx automatic clustering initially formed 25 clusters and the bounded run
forced that result down to the configured maximum of four. It did not infer the
known count of three. The exact-count result is promising, but making it the
default would require either a participant-count hint or a more reliable count
selection policy.

The tested LS-EEND variant is not a useful fallback for this recording. It
emitted 1,185 short spans and its dominant slot overlaps the three VBx clusters
38%, 34% and 28%. A different checkpoint or tuning may behave differently, but
this result gives no reason to integrate the tested AMI variant.

## Human-labelled result

The diagnostic pass produced 208 labels spread across the call: 78 A, 53 B, 60
C, 16 Mixed and one Unclear. The identity score excludes Mixed and Unclear. It
uses the best one-to-one mapping between anonymous model slots and human
speakers, weighted both by transcript-row duration and row count.

| Run | Duration accuracy | Row accuracy |
|---|---:|---:|
| Offline Sortformer v2.1, current | 44.9% | 45.0% |
| Stateful Sortformer high-context | 93.7% | 86.4% |
| Offline VBx, known count 3 | 95.2% | 82.2% |
| Offline VBx, bounded 1 to 4 | 93.2% | 80.1% |
| LS-EEND AMI, 500 ms | 47.7% | 37.2% |

The current model is conclusively unsuitable. Even allowing multiple offline
Sortformer slots to map to the same human speaker raises it only to 51.2%
duration accuracy. Its four slots are acoustically mixed, not merely split.

Stateful Sortformer has a different and repairable error. Its three main slots
are 97% to 98% pure against the human labels. Its short fourth slot is 67% A and
33% C, and the dominant A part duplicates the main A slot. If both A slots are
allowed to merge, stateful Sortformer reaches 96.6% duration and 92.1% row
accuracy. This is an upper bound derived from human labels, not yet an automatic
merge result.

VBx with the known count remains the best result without post-processing. Its
three slots are 99% A, 94% B and 99% C on labelled duration. Its lower row
accuracy comes mainly from leaving short transcript rows unassigned. Stateful
Sortformer covers more of those short rows.

## Diagnostic viewer

`tools/diarization-lab` is a local read-only session viewer. It serves the
retained remote audio with range requests, aligns each model run to all 484
remote transcript rows, plays individual rows, displays assignment purity and
lets a human label each row A, B, C, Mixed or Unclear.

Labels are written atomically outside the recording under a path keyed by the
remote audio SHA-256. Once identity labels exist, the viewer finds the best
one-to-one anonymous-slot mapping for every model and reports duration-weighted
and row accuracy. The one-to-one constraint penalizes a model that splits one
person into two slots.

The first version labels complete transcript rows. `Mixed` identifies rows that
need finer boundary annotation; it does not yet support a manual split inside a
row. This keeps the initial feedback loop small while preserving the evidence
needed to decide whether fine-grained editing is worth building.

## Decision and production check

Quill now uses VBx with an explicit speaker count for long-form separation.
Automatic VBx remains available as a less-reliable fallback. Offline Sortformer
is not retained for this path: its missing cross-window speaker state is
structural, and boundary stitching cannot recover identity confusion that
already happened inside each window.

The production engine completed the retained 50:43 remote track with an exact
count of three and returned three speakers. The installed review flow then
reprocessed that meeting successfully; human review found the resulting speaker
separation correct. This exercises FluidAudio model loading, chunk progress,
VBx clustering, transcript reassignment, atomic publication and the native
review workflow together.

Stateful Sortformer's possible duplicate-slot merge and finer transcript-row
splitting remain research options, not prerequisites for the production path.
The diagnostic viewer stays project-local so future FluidAudio model changes
can be compared against human labels without rebuilding the annotation loop.
