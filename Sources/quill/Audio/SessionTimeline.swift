import Foundation

enum SessionTimeline {
    static func startOffsets(
        microphoneStartedAt microphone: Date,
        systemStartedAt system: Date
    ) -> SessionTrackOffsets {
        let earliest = min(microphone, system)
        return SessionTrackOffsets(
            microphone: milliseconds(microphone.timeIntervalSince(earliest)),
            system: milliseconds(system.timeIntervalSince(earliest))
        )
    }

    static func frameOffset(
        of track: SourceTrack,
        relativeTo reference: SourceTrack,
        startOffsets: SessionTrackOffsets,
        sampleRate: Double
    ) -> Int64 {
        let milliseconds = startOffsets[track] - startOffsets[reference]
        return Int64((Double(milliseconds) * sampleRate / 1000).rounded())
    }

    /// Where a resumed segment's tracks fall on the session's existing timeline.
    static func resumedOffsets(
        origin: Date,
        microphoneStartedAt microphone: Date,
        systemStartedAt system: Date
    ) -> SessionTrackOffsets {
        SessionTrackOffsets(
            microphone: milliseconds(microphone.timeIntervalSince(origin)),
            system: milliseconds(system.timeIntervalSince(origin))
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}
