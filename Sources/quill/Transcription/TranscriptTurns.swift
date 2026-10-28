import Foundation

/// One person's stretch of speech, derived from sentence rows each time a
/// transcript is shown or rendered. `transcript.json` keeps the rows, because
/// separation, repeat and undo reassign speakers row by row.
struct TranscriptTurn: Equatable, Sendable {
    enum Part: Equatable, Sendable {
        case speech(String)
        /// A short unassigned row joined to this speaker's words as a guess.
        case guess(String)
        /// Another person's short replies inside this turn, such as "yeah".
        case replies(speaker: String, text: String)
    }

    let speaker: String
    let voiceID: String?
    let startMilliseconds: Int
    let paragraphs: [[Part]]

    var paragraphTexts: [String] {
        paragraphs.map { paragraph in
            paragraph.map { part in
                switch part {
                case .speech(let text), .guess(let text): text
                case .replies(let speaker, let text): "[\(speaker): \(text)]"
                }
            }.joined(separator: " ")
        }
    }
}

extension TranscriptDocument {
    var turns: [TranscriptTurn] { TranscriptTurns(segments: segments).turns() }
}

struct TranscriptTurns {
    static let paragraphPauseMilliseconds = 1_500
    static let paragraphWords = 120
    /// A long paragraph splits only when this much of the turn is left, so a
    /// turn never ends on a stub.
    static let paragraphTailWords = 40
    static let inlineUnassignedWords = 5

    /// A row is a reply only when its whole text, ignoring case and
    /// punctuation, is one of these: "Yeah." is a reply, "Yeah, that's fine."
    /// is speech.
    static let replies: Set<String> = [
        "yeah", "yep", "yes", "yup", "mm", "mmm", "mm-hmm", "mhm", "hmm", "uh-huh",
        "right", "okay", "ok", "sure", "cool", "nice", "great", "true", "exactly",
        "totally", "absolutely", "oh", "wow", "good", "alright", "all right", "gotcha",
        "got it", "sweet", "perfect", "correct", "interesting", "really", "fair enough",
        "agreed", "definitely", "awesome", "lovely", "brilliant", "makes sense",
        "yeah yeah", "yeah yeah yeah", "okay okay", "oh okay", "oh yeah", "oh right",
        "right right", "yep yep", "okay cool", "yeah okay", "okay yeah", "yeah right",
        "yeah exactly", "oh wow", "no", "nice one", "good good", "mm yeah", "yes yes",
        "thank you", "thanks", "yeah sure", "sure sure",
    ]
    static let fillers: Set<String> = [
        "uh", "um", "er", "erm", "ah", "hm", "uh um", "um um", "uh uh",
    ]

    private enum Kind { case filler, reply, speech }

    private enum Item {
        case text(Int), guess(Int), reply(Int)

        var wordsIndex: Int? {
            switch self {
            case .text(let index), .guess(let index): index
            case .reply: nil
            }
        }
    }

    private struct Working {
        let speaker: String
        let voiceID: String?
        let start: Int
        let unassigned: Bool
        var items: [Item]
        var last: Int
    }

    let segments: [TranscriptDocument.Segment]
    private let kinds: [Kind]

    init(segments: [TranscriptDocument.Segment]) {
        self.segments = segments
        kinds = segments.map { Self.kind($0.text) }
    }

    func turns() -> [TranscriptTurn] {
        var turns: [Working] = []
        var pending: [Int] = []
        func flush(_ turn: Int) {
            turns[turn].items += pending.map(Item.reply)
            pending = []
        }

        for index in segments.indices {
            let segment = segments[index]
            if kinds[index] == .filler, !turns.isEmpty { continue }
            if let current = turns.indices.last {
                if
                    segment.speaker == turns[current].speaker,
                    isUnassigned(index) == turns[current].unassigned
                {
                    turns[current].items.append(.text(index))
                    turns[current].last = index
                    if Self.endsSentence(segment.text), !pending.isEmpty { flush(current) }
                    continue
                }
                // An answer to the speaker's question is a turn, not a reply.
                let asked = Self.trimmed(segments[turns[current].last].text).hasSuffix("?")
                if
                    !turns[current].unassigned, !asked, embeddable(index),
                    let next = nextSpeech(after: index),
                    segments[next].speaker == turns[current].speaker
                {
                    if isFragment(index) {
                        turns[current].items.append(.guess(index))
                        turns[current].last = index
                    } else if
                        Self.endsSentence(segments[turns[current].last].text),
                        pending.isEmpty
                    {
                        turns[current].items.append(.reply(index))
                    } else {
                        // Mid-sentence, so the reply waits for the sentence to end.
                        pending.append(index)
                    }
                    continue
                }
                if !pending.isEmpty { flush(current) }
            }
            turns.append(Working(
                speaker: segment.speaker, voiceID: segment.voice_id,
                start: segment.start_ms, unassigned: isUnassigned(index),
                items: [.text(index)], last: index
            ))
        }
        if let last = turns.indices.last, !pending.isEmpty { flush(last) }

        return turns.map { turn in
            TranscriptTurn(
                speaker: turn.speaker,
                voiceID: turn.voiceID,
                startMilliseconds: turn.start,
                paragraphs: paragraphs(turn.items).map(parts)
            )
        }
    }

    private func paragraphs(_ items: [Item]) -> [[Item]] {
        let total = items.compactMap(\.wordsIndex).reduce(0) { $0 + Self.words(segments[$1].text) }
        var paragraphs: [[Item]] = []
        var paragraph: [Item] = []
        var count = 0, seen = 0
        var previous: Int?
        for item in items {
            if
                let index = item.wordsIndex, let previous, !paragraph.isEmpty,
                Self.endsSentence(segments[previous].text),
                Self.startsSentence(segments[index].text),
                longestSilence(after: previous, before: index) >= Self.paragraphPauseMilliseconds
                    || (count >= Self.paragraphWords && total - seen >= Self.paragraphTailWords)
            {
                paragraphs.append(paragraph)
                paragraph = []
                count = 0
            }
            paragraph.append(item)
            if let index = item.wordsIndex {
                let words = Self.words(segments[index].text)
                count += words
                seen += words
                previous = index
            }
        }
        if !paragraph.isEmpty { paragraphs.append(paragraph) }
        return paragraphs
    }

    private func parts(_ paragraph: [Item]) -> [TranscriptTurn.Part] {
        var parts: [TranscriptTurn.Part] = []
        var run: [Int] = []
        func closeRun() {
            var position = 0
            while position < run.count {
                let speaker = segments[run[position]].speaker
                var said: [String] = []
                while position < run.count, segments[run[position]].speaker == speaker {
                    said.append(Self.reply(segments[run[position]].text))
                    position += 1
                }
                parts.append(.replies(speaker: speaker, text: said.joined(separator: ", ")))
            }
            run = []
        }
        for item in paragraph {
            switch item {
            case .reply(let index):
                run.append(index)
            case .text(let index):
                closeRun()
                parts.append(.speech(Self.trimmed(segments[index].text)))
            case .guess(let index):
                closeRun()
                parts.append(.guess(Self.trimmed(segments[index].text)))
            }
        }
        closeRun()
        return parts
    }

    /// Anyone's speech ends a silence, including replies shown inline or
    /// hidden, or another person's "yeah" breaks the speaker's paragraph.
    private func longestSilence(after previous: Int, before next: Int) -> Int {
        let from = segments[previous].end_ms, to = segments[next].start_ms
        var edge = from, longest = 0
        for index in 0..<next where segments[index].end_ms > from && segments[index].start_ms < to {
            longest = max(longest, segments[index].start_ms - edge)
            edge = max(edge, segments[index].end_ms)
        }
        return max(longest, to - edge)
    }

    private func nextSpeech(after index: Int) -> Int? {
        segments.indices.dropFirst(index + 1).first {
            kinds[$0] == .speech && !isFragment($0)
        }
    }

    private func isUnassigned(_ index: Int) -> Bool { segments[index].isUnassigned }

    private func isFragment(_ index: Int) -> Bool {
        kinds[index] != .reply && isUnassigned(index)
            && Self.words(segments[index].text) <= Self.inlineUnassignedWords
    }

    private func embeddable(_ index: Int) -> Bool {
        kinds[index] == .reply || isFragment(index)
    }

    private static let replyCharacters = Set("abcdefghijklmnopqrstuvwxyz'-")

    private static func kind(_ text: String) -> Kind {
        let normalized = text.lowercased()
            .split { !replyCharacters.contains($0) }
            .joined(separator: " ")
        if normalized.isEmpty {
            // "2006." has no letters but is still speech.
            return text.contains(where: { $0.isLetter || $0.isNumber }) ? .speech : .filler
        }
        if fillers.contains(normalized) { return .filler }
        return replies.contains(normalized) ? .reply : .speech
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reply(_ text: String) -> String {
        var text = trimmed(text)
        while let last = text.last, last == "." || last == "!" { text.removeLast() }
        return trimmed(text)
    }

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func endsSentence(_ text: String) -> Bool {
        trimmed(text).last.map { ".?!".contains($0) } ?? false
    }

    private static func startsSentence(_ text: String) -> Bool {
        guard let first = trimmed(text).first else { return true }
        return !(first.isASCII && first.isLowercase)
    }
}
