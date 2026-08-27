import FluidAudio
import Foundation

enum SpeakerCountSelection: Sendable, Equatable {
    case exact(Int)
    case automatic

    var description: String {
        switch self {
        case .exact(let count): "exactly \(count)"
        case .automatic: "automatic"
        }
    }
}

/// Within-track speaker diarization using FluidAudio's long-form offline VBx
/// pipeline. Microphone and system audio remain separate tracks before this
/// stage.
actor DiarizationEngine {
    struct Span: Sendable {
        let speaker: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Analysis: Sendable {
        let spans: [Span]
        let timings: PipelineTimings?
    }

    enum EngineError: Error, CustomStringConvertible {
        case notPrepared

        var description: String {
            switch self {
            case .notPrepared: "diarization engine used before prepare()"
            }
        }
    }

    nonisolated let model = "offline-vbx-community-1"

    private var models: OfflineDiarizerModels?

    func prepare() async throws {
        guard models == nil else { return }
        models = try await OfflineDiarizerModels.load()
    }

    func analyse(
        _ audio: URL,
        speakerCount: SpeakerCountSelection,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Analysis {
        guard let models else { throw EngineError.notPrepared }
        let config: OfflineDiarizerConfig
        switch speakerCount {
        case .exact(let count):
            config = OfflineDiarizerConfig.default.withSpeakers(exactly: count)
        case .automatic:
            config = .default
        }
        let diarizer = OfflineDiarizerManager(config: config)
        diarizer.initialize(models: models)
        let result = try await diarizer.process(audio, progressCallback: progress)

        let speakerIDs = Array(Set(result.segments.map(\.speakerId))).sorted()
        let speakerNumbers = Dictionary(
            uniqueKeysWithValues: speakerIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let spans = result.segments.compactMap { segment -> Span? in
            guard let speaker = speakerNumbers[segment.speakerId] else { return nil }
            return Span(
                speaker: speaker,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }.sorted { $0.start < $1.start }
        return Analysis(spans: spans, timings: result.timings)
    }

    func release() {
        models = nil
    }

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
            if shared > bestOverlap || (shared == bestOverlap && speaker < best ?? Int.max) {
                best = speaker
                bestOverlap = shared
            }
        }
        return best
    }
}
