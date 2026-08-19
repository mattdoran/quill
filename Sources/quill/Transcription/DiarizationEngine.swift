import FluidAudio
import Foundation

/// Speaker diarization over a single track, via FluidAudio's offline Sortformer
/// model — the same dependency as the ASR engine, sharing its managed model
/// cache.
///
/// Note the two senses of the word here: the mic-vs-system split is already
/// diarization, across tracks and exact. This is the within-track kind, for
/// when one track carries several people anyway — a group call collapsing into
/// an undifferentiated `them`, or an in-person meeting where the whole room
/// shares the microphone.
///
/// Offline, not streaming — the model sees the whole conversation before
/// assigning identities, so someone who speaks at 00:02 and again at 40:00 gets
/// the same label. A session is a complete file by the time it is transcribed.
///
/// The model has four output slots, so at most four speakers per track.
actor DiarizationEngine {
    /// A stretch of speech in track-local seconds, attributed to one of the
    /// diarizer's speaker slots.
    struct Span: Sendable {
        let speaker: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    enum EngineError: Error, CustomStringConvertible {
        case notPrepared

        var description: String {
            switch self {
            case .notPrepared: return "diarization engine used before prepare()"
            }
        }
    }

    nonisolated let model = "sortformer-offline-v2.1"

    private var diarizer: OfflineSortformerDiarizer?

    func prepare() async throws {
        guard diarizer == nil else { return }
        let diarizer = OfflineSortformerDiarizer()
        try await diarizer.initializeFromHuggingFace()
        self.diarizer = diarizer
    }

    /// Speech spans for a complete track, in track-local time. Sorted by start
    /// so callers can walk it alongside transcript segments.
    func spans(for audio: URL) throws -> [Span] {
        guard let diarizer else { throw EngineError.notPrepared }
        let timeline = try diarizer.processComplete(audioFileURL: audio)

        var spans: [Span] = []
        for (index, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments {
                spans.append(Span(
                    speaker: index,
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime)
                ))
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    func release() {
        diarizer = nil
    }

    // MARK: -

    /// Attribution rather than diarization: this consumes `spans` and decides
    /// what each transcript segment is called, giving every segment the speaker
    /// it overlaps most.
    ///
    /// Numbering follows first appearance, not the model's arbitrary slot
    /// indices — `them 1` is whoever spoke first, which is readable and stable
    /// across re-runs.
    ///
    /// Returns one label per segment, positionally.
    ///
    /// One speaker means nothing to disambiguate, so everything gets `solo`: a
    /// track that turns out to hold one person should not acquire a `room 1`
    /// that never contrasts with anything, and on the mic that one person is
    /// whoever owns the machine.
    ///
    /// A segment overlapping no span — the diarizer heard no speech where the
    /// ASR found words — gets the unnumbered `shared` label. Among several
    /// speakers "someone in the room" is honest; naming one would be a guess.
    static func labels(
        for segments: [TranscriptSegment],
        spans: [Span],
        solo: String,
        shared: String
    ) -> [String] {
        guard !spans.isEmpty else { return segments.map { _ in solo } }

        let dominant = assignments(for: segments, spans: spans)

        var ordinal: [Int: Int] = [:]
        for speaker in dominant {
            guard let speaker, ordinal[speaker] == nil else { continue }
            ordinal[speaker] = ordinal.count + 1
        }

        guard ordinal.count > 1 else { return segments.map { _ in solo } }

        return dominant.map { speaker in
            guard let speaker, let n = ordinal[speaker] else { return shared }
            return "\(shared) \(n)"
        }
    }

    static func assignments(
        for segments: [TranscriptSegment], spans: [Span]
    ) -> [Int?] {
        segments.map { segment in
            Self.dominantSpeaker(from: segment.start, to: segment.end, spans: spans)
        }
    }

    /// The speaker with the most overlap across `[start, end)`, or nil when the
    /// segment overlaps no span. Ties break toward the lower slot index so the
    /// result doesn't depend on dictionary ordering.
    private static func dominantSpeaker(
        from start: TimeInterval,
        to end: TimeInterval,
        spans: [Span]
    ) -> Int? {
        var overlap: [Int: TimeInterval] = [:]
        for span in spans {
            let shared = min(end, span.end) - max(start, span.start)
            guard shared > 0 else { continue }
            overlap[span.speaker, default: 0] += shared
        }

        var best: Int?
        var bestOverlap: TimeInterval = 0
        for (speaker, shared) in overlap {
            // Strictly greater, then lower index on a tie, so the result never
            // depends on dictionary ordering.
            if shared > bestOverlap || (shared == bestOverlap && speaker < best ?? Int.max) {
                best = speaker
                bestOverlap = shared
            }
        }
        return best
    }
}
