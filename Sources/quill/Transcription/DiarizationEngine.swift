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
        let speakerEmbeddings: [Int: [Float]]
        /// Similarity of each pair of voices folded together as one person.
        let mergedVoiceSimilarities: [Float]

        init(
            spans: [Span],
            timings: PipelineTimings?,
            speakerEmbeddings: [Int: [Float]] = [:],
            mergedVoiceSimilarities: [Float] = []
        ) {
            self.spans = spans
            self.timings = timings
            self.speakerEmbeddings = speakerEmbeddings
            self.mergedVoiceSimilarities = mergedVoiceSimilarities
        }
    }

    /// An exact count above the number of distinguishable voices is met by
    /// splitting the voice with the most speech. Measured same-person splits
    /// scored 0.94 and 0.97; different people scored at most 0.62.
    static let sameVoiceSimilarity: Float = 0.8

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
        let speakerEmbeddings = (result.speakerDatabase ?? [:]).reduce(
            into: [Int: [Float]]()
        ) { embeddings, entry in
            guard
                let speaker = speakerNumbers[entry.key],
                VoiceEmbedding.isUsable(entry.value)
            else { return }
            embeddings[speaker] = entry.value
        }
        return Self.mergingSameVoices(Analysis(
            spans: spans,
            timings: result.timings,
            speakerEmbeddings: speakerEmbeddings
        ))
    }

    static func mergingSameVoices(
        _ analysis: Analysis, threshold: Float = sameVoiceSimilarity
    ) -> Analysis {
        var centroids = analysis.speakerEmbeddings.mapValues(VoiceEmbedding.normalized)
        var speech = analysis.spans.reduce(into: [Int: TimeInterval]()) {
            $0[$1.speaker, default: 0] += max(0, $1.end - $1.start)
        }
        var survivor: [Int: Int] = [:]
        var similarities: [Float] = []

        while true {
            let speakers = centroids.keys.sorted()
            var best: (keep: Int, drop: Int, similarity: Float)?
            for (index, lhs) in speakers.enumerated() {
                for rhs in speakers[(index + 1)...] {
                    let similarity = VoiceEmbedding.cosineSimilarity(centroids[lhs]!, centroids[rhs]!)
                    guard similarity >= threshold, similarity > best?.similarity ?? -.infinity
                    else { continue }
                    let keepLHS = speech[lhs, default: 0] >= speech[rhs, default: 0]
                    best = (keepLHS ? lhs : rhs, keepLHS ? rhs : lhs, similarity)
                }
            }
            guard let best else { break }

            let keptSpeech = speech[best.keep, default: 0]
            let droppedSpeech = speech[best.drop, default: 0]
            let total = keptSpeech + droppedSpeech
            let keptWeight = total > 0 ? keptSpeech / total : 0.5
            centroids[best.keep] = VoiceEmbedding.normalized(
                zip(centroids[best.keep]!, centroids[best.drop]!).map {
                    Float(Double($0) * keptWeight + Double($1) * (1 - keptWeight))
                }
            )
            centroids[best.drop] = nil
            speech[best.keep] = total
            speech[best.drop] = nil
            for (speaker, target) in survivor where target == best.drop {
                survivor[speaker] = best.keep
            }
            survivor[best.drop] = best.keep
            similarities.append(best.similarity)
        }
        guard !similarities.isEmpty else { return analysis }

        let remaining = Set(analysis.spans.map { survivor[$0.speaker] ?? $0.speaker })
            .union(centroids.keys)
            .sorted()
        let renumbered = Dictionary(
            uniqueKeysWithValues: remaining.enumerated().map { ($0.element, $0.offset) }
        )
        let spans = analysis.spans.map { span in
            Span(
                speaker: renumbered[survivor[span.speaker] ?? span.speaker]!,
                start: span.start,
                end: span.end
            )
        }
        let embeddings = Dictionary(
            uniqueKeysWithValues: centroids.map { (renumbered[$0.key]!, $0.value) }
        )
        return Analysis(
            spans: spans,
            timings: analysis.timings,
            speakerEmbeddings: embeddings,
            mergedVoiceSimilarities: similarities
        )
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
