import FluidAudio
import Foundation
import Network

/// Fetches the transcription models before a meeting needs them.
///
/// Left alone, the ~600 MB download happens inside the first transcription,
/// which is the worst possible moment: the recording is over and the user is
/// waiting for the thing they recorded it for. This pulls it forward to
/// launch, where nobody is waiting.
///
/// It does not download on a metered connection. `NWPathMonitor` reports
/// tethering and Low Data Mode, and 600 MB through a phone is not a decision
/// to make on someone's behalf.
actor ModelDownload {
    enum Status: Sendable, Equatable {
        case idle
        case downloading(fraction: Double)
        /// Waiting for a connection worth using. The menu offers to go ahead.
        case waitingForNetwork
        case failed
    }

    private var handler: (@Sendable (Status) -> Void)?
    private var running = false
    private var monitor: NWPathMonitor?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        self.handler = handler
    }

    /// Already cached, so nothing will be downloaded and nothing shown.
    nonisolated static var isCached: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

    /// Fetch unless the models are present, a fetch is already running, or the
    /// connection is metered. `force` is the menu saying "do it anyway".
    func fetchIfNeeded(force: Bool = false) async {
        guard !Self.isCached, !running else { return }
        if !force, await isMetered() {
            publish(.waitingForNetwork)
            return
        }
        running = true
        defer { running = false }

        publish(.downloading(fraction: 0))
        do {
            // Downloads without loading into memory, and resolves its own
            // cache directory, so the prefetch cannot land the files somewhere
            // the loader will not look for them.
            _ = try await AsrModels.download(
                version: .v2,
                progressHandler: { [weak self] progress in
                    Task { await self?.publish(.downloading(fraction: progress.fractionCompleted)) }
                }
            )
            publish(.idle)
        } catch {
            FileHandle.standardError.write(Data(
                "model download failed: \(error)\n".utf8
            ))
            publish(.failed)
        }
    }

    private func publish(_ status: Status) {
        handler?(status)
    }

    /// One-shot look at the current path. The monitor is torn down immediately:
    /// this decides whether to start a download now, not whether to watch for
    /// a better connection later.
    private func isMetered() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "com.mattdoran.quill.network"))
        }
    }
}
