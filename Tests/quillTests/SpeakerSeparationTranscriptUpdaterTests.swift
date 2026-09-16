import Foundation
import Testing
@testable import quill

@Suite struct SpeakerSeparationTranscriptUpdaterTests {
    @Test func combinedLocalAndRemoteSeparationKeepsTextTimingAndMarkdown() throws {
        let baseline = fixture()
        let separated = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: baseline,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .microphone,
                    spans: [
                        .init(speaker: 10, start: 0.0, end: 0.8),
                        .init(speaker: 20, start: 2.0, end: 2.8),
                    ]
                ),
                analysis(
                    .system,
                    spans: [
                        .init(speaker: 3, start: 1.0, end: 1.8),
                        .init(speaker: 4, start: 3.0, end: 3.8),
                        .init(speaker: 5, start: 4.0, end: 4.8),
                        .init(speaker: 6, start: 5.0, end: 5.8),
                    ]
                ),
            ]
        )

        #expect(separated.voices.values.filter { $0.source == "mic" }.count == 2)
        #expect(separated.voices.values.filter { $0.source == "system" }.count == 4)
        #expect(separated.voiceIDs == [
            "mic:1", "mic:2", "system:1", "system:2", "system:3", "system:4",
        ])
        #expect(separated.voiceIDs.map { separated.voices[$0]?.machine_label } == [
            "Voice 1", "Voice 2", "Voice 3", "Voice 4", "Voice 5", "Voice 6",
        ])
        #expect(separated.segments.map(\.text) == baseline.segments.map(\.text))
        #expect(separated.segments.map(\.start_ms) == baseline.segments.map(\.start_ms))
        #expect(separated.segments.map(\.end_ms) == baseline.segments.map(\.end_ms))
        #expect(separated.segments.map(\.speaker) == [
            "Voice 1", "Voice 3", "Voice 2", "Voice 4", "Voice 5", "Voice 6",
        ])
        let markdown = separated.rendered(title: "Hybrid")
        #expect(markdown.contains("**[0:00] Voice 1:** local one"))
        #expect(markdown.contains("**[0:05] Voice 6:** remote four"))
    }

    @Test func sequentialSeparationPreservesEarlierTrackNames() throws {
        let baseline = fixture()
        var local = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: baseline,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .microphone,
                    spans: [
                        .init(speaker: 1, start: 0.0, end: 0.8),
                        .init(speaker: 2, start: 2.0, end: 2.8),
                    ]
                ),
            ]
        )
        try local.applyVoiceNames(["mic:1": "Eugene", "mic:2": "Susan"])

        let hybrid = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: local,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .system,
                    spans: [
                        .init(speaker: 1, start: 1.0, end: 1.8),
                        .init(speaker: 2, start: 3.0, end: 3.8),
                        .init(speaker: 3, start: 4.0, end: 4.8),
                        .init(speaker: 4, start: 5.0, end: 5.8),
                    ]
                ),
            ]
        )

        #expect(hybrid.voices["mic:1"]?.name == "Eugene")
        #expect(hybrid.voices["mic:2"]?.name == "Susan")
        #expect(hybrid.segments[0].speaker == "Eugene")
        #expect(hybrid.segments[2].speaker == "Susan")
        #expect(hybrid.voiceIDs.map { hybrid.voices[$0]?.machine_label } == [
            "Voice 1", "Voice 2", "Voice 3", "Voice 4", "Voice 5", "Voice 6",
        ])
    }

    @Test func rerunningOneTrackKeepsTheOtherTrackAndAvoidsDuplicateMachineLabels() throws {
        let baseline = fixture()
        var hybrid = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: baseline,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .microphone,
                    spans: [
                        .init(speaker: 1, start: 0.0, end: 0.8),
                        .init(speaker: 2, start: 2.0, end: 2.8),
                    ]
                ),
                analysis(
                    .system,
                    spans: [
                        .init(speaker: 1, start: 1.0, end: 1.8),
                        .init(speaker: 2, start: 3.0, end: 3.8),
                        .init(speaker: 3, start: 4.0, end: 4.8),
                        .init(speaker: 4, start: 5.0, end: 5.8),
                    ]
                ),
            ]
        )
        try hybrid.applyVoiceNames(["system:1": "Remote A"])

        let rerun = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: hybrid,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .microphone,
                    spans: [
                        .init(speaker: 9, start: 0.0, end: 2.8),
                    ]
                ),
            ]
        )

        #expect(rerun.voices.values.filter { $0.source == "mic" }.count == 1)
        #expect(rerun.voices.values.filter { $0.source == "system" }.count == 4)
        #expect(rerun.voices["system:1"]?.name == "Remote A")
        #expect(rerun.segments[1].speaker == "Remote A")
        let machineLabels = rerun.voices.values.map(\.machine_label)
        #expect(Set(machineLabels).count == machineLabels.count)
        #expect(rerun.voices["mic:1"]?.machine_label == "Voice 7")
    }

    @Test func singleVoiceRerunCarriesCurrentDisplayedName() throws {
        let baseline = fixture()
        var displayed = baseline
        try displayed.applyVoiceNames(["mic:1": "Eugene"])

        let rerun = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: displayed,
            diarizer: "test-diarizer",
            analyses: [
                analysis(
                    .microphone,
                    spans: [.init(speaker: 1, start: 0.0, end: 2.8)]
                ),
            ]
        )

        #expect(rerun.voices["mic:1"]?.name == "Eugene")
        #expect(rerun.segments[0].speaker == "Eugene")
        #expect(rerun.segments[2].speaker == "Eugene")
    }

    @Test func incompatibleDisplayedShapeFailsBeforePublishing() throws {
        let baseline = fixture()
        var displayed = baseline
        displayed.segments.removeLast()

        #expect(throws: SpeakerSeparationTranscriptUpdater.UpdateError.self) {
            try SpeakerSeparationTranscriptUpdater.apply(
                baseline: baseline,
                displayed: displayed,
                diarizer: "test-diarizer",
                analyses: [
                    analysis(
                        .microphone,
                        spans: [.init(speaker: 1, start: 0.0, end: 0.8)]
                    ),
                ]
            )
        }
    }

    @Test func separatedVoicesCarryMatchingSpeakerEmbeddings() throws {
        let baseline = fixture()
        let separated = try SpeakerSeparationTranscriptUpdater.apply(
            baseline: baseline,
            displayed: baseline,
            diarizer: "offline-vbx-community-1",
            analyses: [
                analysis(
                    .microphone,
                    spans: [
                        .init(speaker: 10, start: 0.0, end: 0.8),
                        .init(speaker: 20, start: 2.0, end: 2.8),
                    ],
                    speakerEmbeddings: [
                        10: [1, 0],
                        20: [0, 1],
                    ]
                ),
            ]
        )

        #expect(separated.voices["mic:1"]?.embedding_model == "offline-vbx-community-1")
        #expect(separated.voices["mic:1"]?.embedding == [1, 0])
        #expect(separated.voices["mic:2"]?.embedding_model == "offline-vbx-community-1")
        #expect(separated.voices["mic:2"]?.embedding == [0, 1])
        #expect(separated.voices["system:1"]?.embedding == nil)
    }


    @Test func displayedTextOrTimingMismatchFailsBeforePublishing() throws {
        let baseline = fixture()
        var displayed = baseline
        displayed.segments[0] = .init(
            speaker: "Me",
            voice_id: "mic:1",
            start_ms: 0,
            end_ms: 800,
            text: "edited local one"
        )

        #expect(throws: SpeakerSeparationTranscriptUpdater.UpdateError.self) {
            try SpeakerSeparationTranscriptUpdater.apply(
                baseline: baseline,
                displayed: displayed,
                diarizer: "test-diarizer",
                analyses: [
                    analysis(
                        .microphone,
                        spans: [.init(speaker: 1, start: 0.0, end: 0.8)]
                    ),
                ]
            )
        }
    }

    @Test func coordinatorRejectsHybridWhenManifestLacksASelectedTrack() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = TranscriptStore(session: session)
        try store.write(fixture())
        try SessionMetadataStore.writeManifest(
            SessionManifest(
                started: "2026-09-16T00:00:00Z",
                files: .init(microphone: "Source Audio/Local.m4a")
            ),
            to: session
        )
        let beforeJSON = try Data(contentsOf: store.jsonURL)
        let beforeMarkdown = try Data(contentsOf: store.markdownURL)

        do {
            try await TranscriptionCoordinator().separateSpeakers(
                in: session,
                selections: [.microphone: .exact(2), .system: .exact(4)]
            )
            Issue.record("Expected hybrid separation to reject a missing selected track")
        } catch {}

        #expect(try Data(contentsOf: store.jsonURL) == beforeJSON)
        #expect(try Data(contentsOf: store.markdownURL) == beforeMarkdown)
    }

    @Test func realCoordinatorHybridSeparationFromEnvironmentSession() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_SESSION"],
              !path.isEmpty
        else {
            return
        }
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-real-hybrid-separation-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: session)
        }
        try FileManager.default.copyItem(at: source, to: session)

        let store = TranscriptStore(session: session)
        let before = try store.read()
        let coordinator = TranscriptionCoordinator()
        try await coordinator.separateSpeakers(
            in: session,
            selections: [.microphone: .exact(2), .system: .exact(4)]
        )

        let after = try store.read()
        #expect(after.voices.values.filter { $0.source == "mic" }.count == 2)
        #expect(after.voices.values.filter { $0.source == "system" }.count == 4)
        #expect(after.voices.values.allSatisfy {
            $0.embedding_model != nil && !($0.embedding?.isEmpty ?? true)
                && ($0.embedding?.allSatisfy(\.isFinite) ?? false)
        })
        #expect(after.segments.map(\.text) == before.segments.map(\.text))
        #expect(after.segments.map(\.start_ms) == before.segments.map(\.start_ms))
        #expect(after.segments.map(\.end_ms) == before.segments.map(\.end_ms))
        let markdown = try String(contentsOf: store.markdownURL, encoding: .utf8)
        #expect(markdown.contains("Voice 1"))
        #expect(markdown.contains("Voice 6"))
    }

    private func analysis(
        _ track: SourceTrack,
        spans: [DiarizationEngine.Span],
        speakerEmbeddings: [Int: [Float]] = [:]
    ) -> SpeakerSeparationTrackAnalysis {
        SpeakerSeparationTrackAnalysis(
            track: track,
            audioFile: track == .microphone
                ? "Source Audio/Local.m4a"
                : "Source Audio/Remote.m4a",
            offsetMilliseconds: 0,
            spans: spans,
            embeddingModel: speakerEmbeddings.isEmpty ? nil : "offline-vbx-community-1",
            speakerEmbeddings: speakerEmbeddings
        )
    }

    private func fixture() -> TranscriptDocument {
        let sample = TranscriptDocument.Voice.Sample(start_ms: 0, end_ms: 1_000)
        return TranscriptDocument(
            schema_version: TranscriptDocument.currentSchemaVersion,
            engine: "parakeet",
            model: "test",
            diarizer: nil,
            created_at: "2026-09-16T00:00:00Z",
            voices: [
                "mic:1": .init(
                    source: "mic",
                    audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me",
                    name: nil,
                    samples: [sample]
                ),
                "system:1": .init(
                    source: "system",
                    audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them",
                    name: nil,
                    samples: [sample]
                ),
            ],
            segments: [
                .init(speaker: "Me", voice_id: "mic:1", start_ms: 0, end_ms: 800, text: "local one"),
                .init(speaker: "Them", voice_id: "system:1", start_ms: 1_000, end_ms: 1_800, text: "remote one"),
                .init(speaker: "Me", voice_id: "mic:1", start_ms: 2_000, end_ms: 2_800, text: "local two"),
                .init(speaker: "Them", voice_id: "system:1", start_ms: 3_000, end_ms: 3_800, text: "remote two"),
                .init(speaker: "Them", voice_id: "system:1", start_ms: 4_000, end_ms: 4_800, text: "remote three"),
                .init(speaker: "Them", voice_id: "system:1", start_ms: 5_000, end_ms: 5_800, text: "remote four"),
            ]
        )
    }

    private func temporarySession() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-speaker-separation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
