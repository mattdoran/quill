# 2026-08-26 long meeting investigation

Session `2026.08.26-0932` ran for 13,364 seconds (3:42:44). Capture,
finalization, transcription and a later speaker-separation pass all completed.
The microphone changed from the MacBook to AirPods and back during capture.

## Outcome

The capture transport was healthy: source durations agreed within 230 ms, all
four published audio files were playable, and both microphone route changes
recovered on their first attempt. The audio content was not healthy throughout.
In a verified 50-second interval, the system track contained no diarizable or
transcribable speech while the microphone contained quiet acoustic pickup of
the remote discussion. The cleaned local track consequently supplied the normal
transcript and was later treated as four local speakers.

The local and remote ASR passes are serial. The local and remote speaker
separation passes were also serial. The pinned Sortformer model uses one CPU core
and supports at most four speakers per source track.

## Timing

| Stage | Elapsed |
|---|---:|
| Close both source writers | about 0.002 s |
| Drain and publish live AEC outputs | about 0.013 s |
| Audio finalization | about 19 s |
| Prepare transcription model | about 3 s |
| Transcribe `Local Cleaned.m4a` | about 46 s |
| Transcribe `Remote.m4a` and publish transcript | about 49 s |
| Total ASR for 7:25:28 of source audio | about 95 s |
| Stop to transcript ready | about 1:57 |
| Separate local speakers | 2:35 |
| Separate remote speakers | 2:33 |
| Total speaker separation | 5:08 |

ASR processed the combined source duration at roughly 281 times realtime. Audio
finalization remuxed Local, Remote, Local Cleaned and the live meeting mix
sequentially. Approximate stages from file times were 3 to 4 seconds for Local,
3 seconds for Remote, 4 seconds for Local Cleaned, 6 seconds for Meeting Audio,
and 3 seconds for remaining validation and metadata work. Future logs record
these stages directly.

Finalization is not re-encoding the three source derivatives. It moves AAC from
recoverable CAF containers into finished M4A containers and verifies each
published output. The live meeting mix was previously decoded completely before
remux and the M4A was then decoded again. The input now receives a duration
check, while the published M4A retains complete decode validation. Parallel
remux remains unproven: four concurrent full-file readers may trade elapsed time
for IO contention, and 19 seconds did not justify that change.

The hidden `check-live-aec` command could not open its AAC/CAF output encoders
in this headless run and returned Core Audio `fmt?`. Renaming the temporary files
to end in `.caf` did not change the failure, so the `.caf.live` suffix is not the
verified cause. The signed app created and finalized both live outputs during
this meeting. Treat the command failure as a test-harness boundary to diagnose,
not as evidence that production live AEC failed.

## Speaker separation

The separation log named `Source Audio/Local.m4a`, but this was a logging bug.
`AudioPreparation` supplied `Source Audio/Local Cleaned.m4a`, and every generated
local voice record points its sample player at that cleaned file.

The result was still wrong. The representative local samples contained remote
meeting speech. Eleven of twelve cleaned samples measured between -57.4 and
-63.8 dBFS RMS; the remaining sample was -47.5 dBFS. Raw-to-clean attenuation
over those samples was only 0.3 to 1.7 dB. The aligned system track measured 15
to 22 dB louder in most samples, but a controlled 50-second replay established
that this energy was not speech: Parakeet and Sortformer both returned no speech
for the system clip.

The same replay of `Local Cleaned.m4a` produced the business discussion in the
normal transcript, and Sortformer found four voices. This confirms that the
quiet signal was transcribed; absolute level did not protect ASR because its
input processing can make low-level intelligible speech usable. It also changes
the AEC diagnosis. This was not speech reduced 16 to 20 dB by AEC. The matching
render reference was absent, so cleaned and raw local remained almost identical
and AEC had nothing from which to cancel the acoustic pickup.

Across all 503 local-labelled transcript segments, only 27 segments totalling
73 seconds measured at or above -50 dBFS RMS. The other 476 segments included
3,847 seconds of text below that threshold. This distribution agrees with the
participant speaking relatively little and shows that the baseline transcript,
not only speaker separation, was contaminated by quiet remote pickup during at
least part of the call.

The transition is sharp. Before 35:59, cleaned local was generally -87 to -90
dBFS and AEC removed about 27 to 29 dB. Immediately after the shared capture
gap, cleaned and raw local differed by only about 0.4 dB and remained that way
until the output route changed. Over the same boundary, Quill's system track
fell from about -21 to -43 dBFS. macOS unified logs continued to report Zen's
downlink and the hardware output near -20 dBFS, so the meeting itself had not
become quieter.

Waveform correlation independently locates the fault. At 34 minutes, raw local
and the system reference had absolute correlation about 0.58 at 111 ms acoustic
delay. From 36 through 58 minutes, correlation was only 0.04 to 0.06 even when
searching a five-second lag range. After returning to MacBook audio it recovered
to about 0.51 at 174 ms. The system reference after the overload was therefore
not merely quiet or shifted; it was no longer the matching playback waveform.

Unified logging at 10:08:17 records two Core Audio timeline re-anchors, repeated
IO-cycle skips and `ClientHALIODurationExceededBudget` overloads. Quill's own
session log recorded only the padded source gaps, so it could not distinguish a
resumed but degraded process tap from healthy capture. Future sessions rebuild
the system tap after a system gap or output-route change, reset AEC3, and log
minute-level near/reference/cleaned RMS plus attenuation.

An offline, timeline-preserving gate was tested on a confirmed 50-second leakage
clip and a louder candidate-local clip. At -50 dB the leakage fell from four
detected voices to one but remained transcribable. At -35 dB it disappeared,
but so did the candidate-local clip. At -45 dB six short leakage spans remained
while the loudest few seconds of the candidate-local clip survived. The gate is
computationally cheap, but these results do not support one fixed threshold.
Any production gate needs calibration or a speech/source confidence rule and a
larger labelled replay set. It should create a temporary analysis input and
must not modify retained audio.

The enriched document contained four local and four remote voice IDs. It also
left 306 transcript segments unassigned, representing 3,311 seconds when their
durations are summed. That scale of unmatched speech is another reason not to
treat this pass as a useful identity result.

For calls, only Remote should normally be separated. Local separation remains
available as a distinct secondary action for in-person rooms, without a modal
warning. The original transcript is now snapshotted before separation so a
completed result can be undone exactly. This session predates that snapshot and
requires ASR to be rerun to recover its exact baseline.

Sortformer has four output slots per track. A remote track containing eight or
more people must merge identities, regardless of runtime or CPU availability.
The current result is not a meaningful quality test for meetings beyond that
limit. A higher-capacity diarizer needs a benchmark against retained real calls
before replacing the stable four-speaker model.

The concrete Sortformer API reports only completion of a whole file. Quill can
show model preparation and the selected source, but cannot honestly show a
within-file percentage. A first implementation exposed queue boundaries as
`0%` and `100%`; live review rejected that false progress. Remote-only
analysis also halves work for the normal call case and avoids the false local
pass. Running two model instances in parallel would increase model memory and
contention and has not been justified by a benchmark.

## Capture and route changes

Initial microphone offset was 191 ms. One shared interruption occurred at
10:08:17: the microphone padded about 0.5 seconds and the system track about 0.7
seconds.

The MacBook-to-AirPods change attached 0.22 seconds after route detection,
resumed in 1.5 seconds and padded 0.5 seconds. The AirPods-to-MacBook change
attached in 0.25 seconds, resumed in 1.0 seconds and padded 0.6 seconds. Both
were first-attempt recoveries and live AEC continued.

Unified logging around the shared interruption showed Core Audio scheduling
latency of 12 to 27 ms and a possible HAL IO budget overrun attributed to Quill's
client. This coincided with an intentional system-load investigation. Zen was
running Google Meet with browser background blur, Granola had heavy hidden
rendering, and metadata indexing was active. Moving blur to the macOS camera
pipeline reduced the browser cost. This is evidence of isolated machine-wide
scheduling contention, not evidence that Quill's capture architecture failed.

## Clock observations

The old whole-epoch summary reported microphone minus system drift of +7.6 ppm,
or +0.071 seconds over 9,338 comparable seconds. That fit crossed inserted
silence and overstated real rate error.

Piecewise results were:

- first MacBook epoch: device about +3.4 ppm; normalized contiguous sections
  about +1.9 and +0.8 ppm, with residuals within 14 ms;
- AirPods epoch: about 0 ppm;
- final MacBook epoch: device and normalized about +3.0 ppm, with residuals
  within 14 ms; and
- contiguous system sections: about 0 ppm.

The best comparable long section implies about +3 ppm, or roughly 28 ms over
9,338 seconds. That does not justify resampling or drift correction. Future
clock observations carry a capture-segment number, and fits split whenever
`TrackWriter` inserts a padded gap. Continue measuring long meetings before
changing the audio timeline.

## Optimization proposals

| Proposal | Decision | Evidence |
|---|---|---|
| Bypass AEC with headphones | Do not implement | Output route does not prove the microphone cannot receive remote audio, and route changes would create AEC state transitions. Live AEC completed without backlog and had negligible stop cost. |
| Poll active inputs less often | Do not change from one second yet | The scanner does issue repeated Core Audio property reads, but this session did not isolate meaningful Quill CPU to the scanner. A slower poll also delays meeting start/end detection. Measure it before trading responsiveness. |
| Tune AEC suppression or filter length | Do not implement from this meeting | Quill currently uses stock WebRTC AEC3 configuration and is tunable in code, but the verified failure interval had no speech in the render reference. No suppressor or filter setting can cancel a signal absent from that reference. Stronger settings also risk near-end and double-talk damage. |
| Gate cleaned local analysis | Continue controlled replay | A gate is cheap and can operate on a temporary offline input. Fixed thresholds between -50 and -35 dB traded leaked speech against candidate local speech in two clips, so calibration or a stronger classifier is required before integration. |
| Batch source writes | Do not implement | Capture callbacks already copy and enqueue whole Core Audio buffers. AAC and disk IO run off the realtime callback. More batching increases crash-loss and memory windows without addressing the observed machine-wide scheduling stall. |
| Capture PCM and encode later | Rejected | It moves CPU out of the meeting at the cost of much larger source files and a long post-meeting encode. The completed AAC pipeline finalized this meeting in about 19 seconds. |
| Parallelize ASR or separation tracks | Benchmark before changing | Current passes are serial and one model pass uses about one CPU core. Parallel model instances may reduce elapsed time but increase model memory and contention. Remote-only diarization removes the unnecessary local pass with less risk. |

## Follow-up

- Keep remote-only separation as the normal call workflow.
- Preserve exact undo for future speaker-separation runs.
- State the four-speaker-per-track limit in the review UI.
- Detect and diagnose periods where the system tap delivers buffers but no
  meeting speech, using retained real calls before choosing an alert policy.
- Build a labelled replay set for local speech, cancelled echo and missing-render
  pickup before selecting an offline analysis gate.
- Report actual prepared filenames and per-stage elapsed times.
- Split drift fits at capture gaps and continue measurement without correction.
- Benchmark a higher-capacity diarizer and parallel model instances separately.
- Keep AAC capture, current AEC settings, one-second call observation and current
  source-writer buffering until direct measurements justify changing them.
