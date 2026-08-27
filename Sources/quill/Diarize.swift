import ArgumentParser
import AVFoundation
import Foundation

/// Run diarization, and optionally transcription, over an arbitrary audio file
/// without recording a session — so speaker detection can be checked against
/// real multi-speaker material in seconds.
struct Diarize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarize",
        abstract: "Diarize an audio file — speaker spans, or a labelled transcript."
    )

    /// Carries a thrown error back across the semaphore. The wait establishes
    /// the ordering, so the unchecked conformance is sound.
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    @Argument(help: "Audio file to diarize (wav, caf, m4a, mp3, …).")
    var file: String

    @Flag(name: .long, help: "Print raw speaker spans only; skip transcription.")
    var spansOnly: Bool = false

    @Option(name: .long, help: "Speaker label prefix (default: \"them\").")
    var speaker: String = "them"

    @Option(name: .long, help: "Exact number of speakers (automatic when omitted).")
    var numSpeakers: Int?

    /// The model loading underneath is async, but the daemon depends on
    /// ArgumentParser calling `Run.run()` synchronously on the main thread, so
    /// the root command stays sync and the async work is confined here.
    func run() throws {
        let box = ErrorBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await diarize() } catch { box.error = error }
            finished.signal()
        }
        finished.wait()
        if let error = box.error { throw error }
    }

    private func diarize() async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("no such file: \(url.path)\n".utf8))
            throw ExitCode(1)
        }

        // Fail on unreadable input before spending minutes on a model download.
        let duration: TimeInterval
        do {
            let probe = try AVAudioFile(forReading: url)
            guard probe.length > 0 else {
                FileHandle.standardError.write(Data(
                    "\(url.lastPathComponent) contains no audio frames\n".utf8
                ))
                throw ExitCode(1)
            }
            duration = Double(probe.length) / probe.fileFormat.sampleRate
        } catch let error as ExitCode {
            throw error
        } catch {
            // AVFoundation reads video containers directly — an .mp4/.mov with
            // an audio track needs no extraction. Failure here means the file
            // is corrupt (a recording that never wrote its index) or in a
            // format CoreAudio doesn't decode.
            FileHandle.standardError.write(Data(
                """
                can't read \(url.lastPathComponent): \(error.localizedDescription)
                check that it decodes at all:
                  ffprobe -v error -show_entries format=duration -of csv=p=0 "\(url.lastPathComponent)"

                """.utf8
            ))
            throw ExitCode(1)
        }

        print("file:     \(url.path)")
        print("duration: \(Self.clock(duration))")

        let started = Date()
        let engine = DiarizationEngine()
        FileHandle.standardError.write(Data("loading diarization model…\n".utf8))
        try await engine.prepare()

        if let numSpeakers, numSpeakers < 1 {
            throw ValidationError("--num-speakers must be at least 1")
        }
        let selection = numSpeakers.map(SpeakerCountSelection.exact) ?? .automatic
        let analysis = try await engine.analyse(
            url,
            speakerCount: selection,
            progress: { completed, total in
                FileHandle.standardError.write(Data(
                    "analysing chunk \(completed)/\(total)\r".utf8
                ))
            }
        )
        FileHandle.standardError.write(Data("\n".utf8))
        let spans = analysis.spans
        let elapsed = Date().timeIntervalSince(started)
        let speakers = Set(spans.map(\.speaker)).sorted()
        print("speakers: \(speakers.count) \(speakers.map { "#\($0)" }.joined(separator: " "))")
        print("spans:    \(spans.count)  (diarized in \(String(format: "%.1f", elapsed))s)")
        print("")

        if spansOnly {
            for span in spans {
                print("  [\(Self.clock(span.start)) → \(Self.clock(span.end))]  #\(span.speaker)")
            }
            return
        }

        FileHandle.standardError.write(Data("transcribing…\n".utf8))
        let asr = ParakeetEngine()
        try await asr.prepare()
        let segments = try await asr.transcribe(url)
        await asr.release()

        guard !segments.isEmpty else {
            print("(no speech transcribed)")
            return
        }

        // One prefix for both roles here: the daemon distinguishes `me` from
        // `room`, but a file handed to this command has no side to be on.
        let labels = DiarizationEngine.labels(
            for: segments, spans: spans, solo: speaker, shared: speaker
        )
        for (segment, label) in zip(segments, labels) {
            print("**[\(Self.clock(segment.start))] \(label):** \(segment.text)")
            print("")
        }

        // Distinct labels, not raw span count: this is what a transcript would
        // actually show after single-speaker collapse and unmatched fallback.
        let distinct = Set(labels).sorted()
        FileHandle.standardError.write(Data(
            "labels: \(distinct.joined(separator: ", "))\n".utf8
        ))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
