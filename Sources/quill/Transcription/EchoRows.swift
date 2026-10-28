import Foundation

/// Local rows that repeat what the call said moments before: the call reaching
/// the microphone through the speakers when echo cancellation fails. They stay
/// in `transcript.json` and are hidden when rendered, since the remote row
/// already holds the words.
enum EchoRows {
    /// Shorter rows agree with the call by chance ("How are you?").
    static let minimumWords = 5
    static let windowMilliseconds = 3_000
    static let matchedShare = 0.6

    /// One flag per row, in the order given. A row is echo only when a remote
    /// row that started first holds most of its words in the same order.
    static func flags(for rows: [TranscriptDocument.Segment]) -> [Bool] {
        let remote = rows.filter { $0.voice_id?.hasPrefix("\(SourceTrack.system.rawValue):") == true }
            .sorted { $0.start_ms < $1.start_ms }
        let local = "\(SourceTrack.microphone.rawValue):"
        return rows.map { row in
            guard row.voice_id?.hasPrefix(local) == true else { return false }
            let said = words(row.text)
            guard said.count >= minimumWords else { return false }
            let heard = remote
                .filter { $0.start_ms <= row.start_ms && $0.end_ms >= row.start_ms - windowMilliseconds }
                .flatMap { words($0.text) }
            return Double(commonWords(said, heard)) >= matchedShare * Double(said.count)
        }
    }

    private static let wordCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789'")

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !wordCharacters.contains($0) }.map(String.init)
    }

    /// Longest common subsequence: shared words in the same order.
    private static func commonWords(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for word in a {
            for (index, other) in b.enumerated() {
                current[index + 1] = word == other
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
