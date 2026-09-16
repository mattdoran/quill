import Foundation

struct SpeakerSeparationTrackAnalysis: Sendable {
    let track: SourceTrack
    let audioFile: String
    let offsetMilliseconds: Int
    let spans: [DiarizationEngine.Span]
    let embeddingModel: String?
    let speakerEmbeddings: [Int: [Float]]

    init(
        track: SourceTrack,
        audioFile: String,
        offsetMilliseconds: Int,
        spans: [DiarizationEngine.Span],
        embeddingModel: String? = nil,
        speakerEmbeddings: [Int: [Float]] = [:]
    ) {
        self.track = track
        self.audioFile = audioFile
        self.offsetMilliseconds = offsetMilliseconds
        self.spans = spans
        self.embeddingModel = embeddingModel
        self.speakerEmbeddings = speakerEmbeddings
    }
}

enum SpeakerSeparationTranscriptUpdater {
    enum UpdateError: Error, LocalizedError {
        case incompatibleTranscript

        var errorDescription: String? {
            switch self {
            case .incompatibleTranscript:
                return "This transcript does not contain the timing information needed for speaker separation."
            }
        }
    }

    static func apply(
        baseline: TranscriptDocument,
        displayed: TranscriptDocument,
        diarizer: String,
        analyses: [SpeakerSeparationTrackAnalysis]
    ) throws -> TranscriptDocument {
        guard baseline.canEditVoices, displayed.canEditVoices else {
            throw TranscriptStore.StoreError.unsupportedSchema
        }
        guard baseline.segments.count == displayed.segments.count else {
            throw UpdateError.incompatibleTranscript
        }
        guard zip(baseline.segments, displayed.segments).allSatisfy({
            $0.start_ms == $1.start_ms && $0.end_ms == $1.end_ms && $0.text == $1.text
        }) else {
            throw UpdateError.incompatibleTranscript
        }

        let selectedTracks = Set(analyses.map(\.track))
        var voices = displayed.voices.filter { _, voice in
            guard let source = SourceTrack(rawValue: voice.source) else { return true }
            return !selectedTracks.contains(source)
        }
        var segments = displayed.segments
        var labelSequence = MachineVoiceLabelSequence(preserving: voices.values.map(\.machine_label))
        var processedTrack = false

        for analysis in analyses {
            let indices = baseline.segments.indices.filter { index in
                source(for: baseline.segments[index], in: baseline) == analysis.track
            }
            guard !indices.isEmpty else { continue }
            processedTrack = true
            for index in indices {
                segments[index] = baseline.segments[index]
            }

            let offset = TimeInterval(analysis.offsetMilliseconds) / 1000
            let timed = indices.map { index in
                TranscriptSegment(
                    start: max(0, TimeInterval(baseline.segments[index].start_ms) / 1000 - offset),
                    end: max(0, TimeInterval(baseline.segments[index].end_ms) / 1000 - offset),
                    text: baseline.segments[index].text
                )
            }
            let assignments = DiarizationEngine.assignments(
                for: timed,
                spans: analysis.spans
            )
            var ordinals: [Int: Int] = [:]
            for assignment in assignments {
                guard let assignment, ordinals[assignment] == nil else { continue }
                ordinals[assignment] = ordinals.count + 1
            }

            if ordinals.isEmpty {
                let id = "\(analysis.track.rawValue):1"
                var voice = makeVoice(
                    source: analysis.track.rawValue,
                    audioFile: analysis.audioFile,
                    label: labelSequence.next(),
                    indices: Array(timed.indices),
                    segments: timed,
                    embeddingModel: nil,
                    embedding: nil
                )
                voice.name = displayed.nameToCarry(
                    source: analysis.track.rawValue,
                    separatedVoiceCount: 1
                )
                voices[id] = voice
                for index in indices {
                    segments[index].speaker = voice.displayName
                    segments[index].voice_id = id
                }
                continue
            }

            for (speaker, ordinal) in ordinals.sorted(by: { $0.value < $1.value }) {
                let id = "\(analysis.track.rawValue):\(ordinal)"
                let positions = assignments.indices.filter { assignments[$0] == speaker }
                var voice = makeVoice(
                    source: analysis.track.rawValue,
                    audioFile: analysis.audioFile,
                    label: labelSequence.next(),
                    indices: positions,
                    segments: timed,
                    embeddingModel: analysis.embeddingModel,
                    embedding: analysis.speakerEmbeddings[speaker]
                )
                voice.name = displayed.nameToCarry(
                    source: analysis.track.rawValue,
                    separatedVoiceCount: ordinals.count
                )
                voices[id] = voice
            }

            for (position, index) in indices.enumerated() {
                guard
                    let speaker = assignments[position],
                    let ordinal = ordinals[speaker]
                else {
                    segments[index].speaker = "Unassigned"
                    segments[index].voice_id = nil
                    continue
                }
                let id = "\(analysis.track.rawValue):\(ordinal)"
                segments[index].speaker = voices[id]?.displayName ?? "Voice \(ordinal)"
                segments[index].voice_id = id
            }
        }

        guard processedTrack else { throw UpdateError.incompatibleTranscript }
        return TranscriptDocument(
            schema_version: displayed.schema_version,
            engine: displayed.engine,
            model: displayed.model,
            diarizer: diarizer,
            created_at: displayed.created_at,
            voices: voices,
            segments: segments
        )
    }

    private static func source(
        for segment: TranscriptDocument.Segment,
        in document: TranscriptDocument
    ) -> SourceTrack? {
        guard
            let voiceID = segment.voice_id,
            let voice = document.voices[voiceID]
        else { return nil }
        return SourceTrack(rawValue: voice.source)
    }

    private static func makeVoice(
        source: String,
        audioFile: String,
        label: String,
        indices: [Int],
        segments: [TranscriptSegment],
        embeddingModel: String?,
        embedding: [Float]?
    ) -> TranscriptDocument.Voice {
        var candidates = indices.map { index in
            let sample = TranscriptDocument.Voice.Sample(
                start_ms: Int(segments[index].start * 1000),
                end_ms: Int(segments[index].end * 1000)
            )
            return (sample, TranscriptionCoordinator.sampleScore(sample, text: segments[index].text))
        }
        candidates.sort { $0.1 > $1.1 }
        return TranscriptDocument.Voice(
            source: source,
            audio_file: audioFile,
            machine_label: label,
            name: nil,
            samples: candidates.prefix(3).map(\.0),
            embedding_model: embeddingModel,
            embedding: embedding
        )
    }
}

private struct MachineVoiceLabelSequence {
    private var used: Set<String>
    private var nextNumber: Int

    init(preserving labels: [String]) {
        used = Set(labels)
        nextNumber = labels.compactMap(Self.voiceNumber).max().map { $0 + 1 } ?? 1
    }

    mutating func next() -> String {
        while used.contains("Voice \(nextNumber)") {
            nextNumber += 1
        }
        let label = "Voice \(nextNumber)"
        used.insert(label)
        nextNumber += 1
        return label
    }

    private static func voiceNumber(_ label: String) -> Int? {
        guard label.hasPrefix("Voice ") else { return nil }
        return Int(label.dropFirst("Voice ".count))
    }
}
