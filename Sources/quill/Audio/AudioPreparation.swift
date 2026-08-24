import Foundation

struct PreparedAudioInputs: Sendable {
    let microphone: URL?
    let system: URL?
    let cleanedMicrophone: URL?

    func source(for track: SourceTrack) -> URL? {
        switch track {
        case .microphone: microphone
        case .system: system
        }
    }

    func transcriptionSource(for track: SourceTrack) -> URL? {
        track == .microphone ? cleanedMicrophone ?? microphone : system
    }
}

enum AudioPreparation {
    enum PreparationError: Error, CustomStringConvertible {
        case unsafePath(String)

        var description: String {
            switch self {
            case .unsafePath(let path): "unsafe session audio path \(path)"
            }
        }
    }

    static func prepare(
        session: URL,
        manifest: SessionManifest,
        log: (String) -> Void
    ) throws -> PreparedAudioInputs {
        let microphone = try url(for: manifest.files.microphone, in: session)
        let system = try url(for: manifest.files.system, in: session)
        var cleaned = try url(for: manifest.files.cleanedMicrophone, in: session)
        if cleaned == nil {
            let internalCleaned = SessionFiles.internalFile(
                EchoCancellation.outputName,
                in: session
            )
            if FileManager.default.fileExists(atPath: internalCleaned.path) {
                cleaned = internalCleaned
            }
        }

        if let candidate = cleaned, let microphone {
            do {
                try EchoCancellation.validateCleaned(candidate, matching: microphone)
            } catch {
                log("cleaned microphone unusable, rebuilding: \(error)")
                self.removeInternalArtifact(candidate, from: session)
                cleaned = nil
            }
        }

        if cleaned == nil, let microphone, let system {
            do {
                log("cleaning speaker playback from \(microphone.lastPathComponent) (AEC3)")
                cleaned = try EchoCancellation.clean(
                    mic: microphone,
                    micOffsetMs: manifest.startOffsets.microphone,
                    system: system,
                    systemOffsetMs: manifest.startOffsets.system,
                    in: try SessionFiles.prepare(session)
                )
                log("cleaned microphone written to \(EchoCancellation.outputName)")
            } catch {
                log("echo cancellation failed, using \(microphone.lastPathComponent): \(error)")
            }
        }

        return PreparedAudioInputs(
            microphone: microphone,
            system: system,
            cleanedMicrophone: cleaned
        )
    }

    static func url(for path: String?, in session: URL) throws -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let components = (path as NSString).pathComponents
        guard !path.hasPrefix("/"), !components.contains("..") else {
            throw PreparationError.unsafePath(path)
        }
        let url = session.appendingPathComponent(path).standardizedFileURL
        let root = session.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root) else { throw PreparationError.unsafePath(path) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func removeInternalArtifact(_ url: URL, from session: URL) {
        let internalRoot = SessionFiles.internalDirectory(session).standardizedFileURL.path + "/"
        // Human-facing audio is evidence even when validation fails.
        guard url.standardizedFileURL.path.hasPrefix(internalRoot) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
