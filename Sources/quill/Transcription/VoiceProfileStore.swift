import Foundation

struct VoiceProfile: Codable, Equatable, Sendable {
    struct Contribution: Codable, Equatable, Sendable {
        let session_id: String
        let voice_id: String
        var embedding: [Float]
        var updated_at: String
    }

    let id: String
    var name: String
    let embedding_model: String
    var embedding: [Float]
    var contribution_count: Int
    let created_at: String
    var updated_at: String
    var contributions: [Contribution]
}

struct VoiceProfileSuggestion: Equatable, Sendable {
    let profileID: String
    let name: String
    let score: Float
}

struct VoiceProfileStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case invalidEmbedding
        case incompatibleProfile
        case unknownProfile(String)
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEmbedding:
                "The voice embedding is not usable."
            case .incompatibleProfile:
                "The remembered voice was created by a different voice model."
            case .unknownProfile(let id):
                "No remembered voice exists for \(id)."
            case .unsupportedSchema:
                "Remembered voices were created by an incompatible version of Quill."
            }
        }
    }

    struct Matching: Sendable {
        var threshold: Float = 0.82
        var margin: Float = 0.05
    }

    private struct Document: Codable {
        var schema_version: Int
        var profiles: [VoiceProfile]
    }

    static let currentSchemaVersion = 1

    var url: URL
    var matching = Matching()

    init(
        url: URL = Config.home.appendingPathComponent("voice-profiles.json"),
        matching: Matching = Matching()
    ) {
        self.url = url
        self.matching = matching
    }

    func load() throws -> [VoiceProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schema_version == Self.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(document.schema_version)
        }
        return document.profiles.filter(Self.isValid)
    }

    func suggestions(for document: TranscriptDocument) throws -> [String: VoiceProfileSuggestion] {
        let profiles = try load()
        var suggestions: [String: VoiceProfileSuggestion] = [:]
        for voiceID in document.voiceIDs {
            guard
                let voice = document.voices[voiceID],
                voice.name?.nilIfBlank == nil,
                let model = voice.embedding_model?.nilIfBlank,
                let embedding = voice.embedding,
                VoiceEmbedding.isUsable(embedding)
            else { continue }

            let sortedCandidates = profiles
                .filter {
                    $0.embedding_model == model
                        && $0.embedding.count == embedding.count
                        && VoiceEmbedding.isUsable($0.embedding)
                }
                .map {
                    (
                        profile: $0,
                        score: VoiceEmbedding.cosineSimilarity(embedding, $0.embedding)
                    )
                }
                .filter { $0.score.isFinite }
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.profile.id < $1.profile.id
                }
            // Two profiles of one name suggest the same thing, so the runner-up
            // that has to trail by the margin is the best other name.
            var names = Set<String>()
            let candidates = sortedCandidates.filter { names.insert(Self.nameKey($0.profile.name)).inserted }

            guard
                let best = candidates.first,
                best.score >= matching.threshold
            else { continue }
            if candidates.count > 1, best.score - candidates[1].score < matching.margin {
                continue
            }
            suggestions[voiceID] = VoiceProfileSuggestion(
                profileID: best.profile.id,
                name: best.profile.name,
                score: best.score
            )
        }
        return suggestions
    }

    @discardableResult
    func remember(
        document: TranscriptDocument,
        sessionID: String,
        voiceIDs: Set<String>
    ) throws -> [String: VoiceProfile] {
        var profiles = try load()
        var remembered: [String: VoiceProfile] = [:]
        let now = Self.timestamp()

        for voiceID in voiceIDs.sorted() {
            guard
                let voice = document.voices[voiceID],
                let name = voice.name?.nilIfBlank,
                let model = voice.embedding_model?.nilIfBlank,
                let rawEmbedding = voice.embedding
            else { continue }
            let embedding = try Self.normalized(rawEmbedding)
            let targetIndex = try targetProfileIndex(
                voice: voice,
                voiceID: voiceID,
                sessionID: sessionID,
                model: model,
                dimension: embedding.count,
                profiles: profiles
            )
            let contribution = VoiceProfile.Contribution(
                session_id: sessionID,
                voice_id: voiceID,
                embedding: embedding,
                updated_at: now
            )
            if let targetIndex {
                try Self.requireCompatible(
                    profiles[targetIndex],
                    model: model,
                    dimension: embedding.count
                )
                profiles[targetIndex].name = name
                Self.upsert(contribution: contribution, into: &profiles[targetIndex], now: now)
                remembered[voiceID] = profiles[targetIndex]
            } else {
                let profile = VoiceProfile(
                    id: UUID().uuidString,
                    name: name,
                    embedding_model: model,
                    embedding: embedding,
                    contribution_count: 1,
                    created_at: now,
                    updated_at: now,
                    contributions: [contribution]
                )
                profiles.append(profile)
                remembered[voiceID] = profile
            }
        }

        try save(profiles)
        return remembered
    }

    func forget(profileID: String) throws {
        var profiles = try load()
        let count = profiles.count
        profiles.removeAll { $0.id == profileID }
        guard profiles.count != count else { throw StoreError.unknownProfile(profileID) }
        try save(profiles)
    }

    func forgetAll() throws {
        try save([])
    }

    /// A profile left without contributions is removed. With a profile ID,
    /// only that profile loses the contribution.
    func forgetContribution(sessionID: String, voiceID: String, profileID: String? = nil) throws {
        try forgetContributions(in: profileID) { $0.session_id == sessionID && $0.voice_id == voiceID }
    }

    /// Separating a track again renumbers its voices, so every contribution
    /// keyed by that track's old voice IDs would name someone else.
    func forgetContributions(sessionID: String, tracks: Set<SourceTrack>) throws {
        let prefixes = tracks.map { "\($0.rawValue):" }
        try forgetContributions { contribution in
            contribution.session_id == sessionID
                && prefixes.contains { contribution.voice_id.hasPrefix($0) }
        }
    }

    private func forgetContributions(
        in profileID: String? = nil,
        where matches: (VoiceProfile.Contribution) -> Bool
    ) throws {
        var profiles = try load()
        let now = Self.timestamp()
        var changed = false
        for index in profiles.indices where profileID == nil || profiles[index].id == profileID {
            let count = profiles[index].contributions.count
            profiles[index].contributions.removeAll(where: matches)
            guard profiles[index].contributions.count != count else { continue }
            changed = true
            profiles[index].embedding = Self.meanEmbedding(profiles[index].contributions.map(\.embedding))
            profiles[index].contribution_count = profiles[index].contributions.count
            profiles[index].updated_at = now
        }
        guard changed else { return }
        profiles.removeAll { $0.contributions.isEmpty }
        try save(profiles)
    }

    private func targetProfileIndex(
        voice: TranscriptDocument.Voice,
        voiceID: String,
        sessionID: String,
        model: String,
        dimension: Int,
        profiles: [VoiceProfile]
    ) throws -> Int? {
        if let id = voice.remembered_profile_id?.nilIfBlank {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            try Self.requireCompatible(profiles[index], model: model, dimension: dimension)
            return index
        }

        return profiles.firstIndex { profile in
            guard
                profile.name == voice.name?.nilIfBlank,
                profile.embedding_model == model,
                profile.embedding.count == dimension,
                VoiceEmbedding.cosineSimilarity(profile.embedding, voice.embedding ?? []) >= matching.threshold
            else { return false }
            return profile.contributions.contains {
                $0.session_id == sessionID && $0.voice_id == voiceID
            }
        }
    }

    private static func nameKey(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func save(_ profiles: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = Document(schema_version: Self.currentSchemaVersion, profiles: profiles)
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private static func upsert(
        contribution: VoiceProfile.Contribution,
        into profile: inout VoiceProfile,
        now: String
    ) {
        if let index = profile.contributions.firstIndex(where: {
            $0.session_id == contribution.session_id && $0.voice_id == contribution.voice_id
        }) {
            profile.contributions[index] = contribution
        } else {
            profile.contributions.append(contribution)
        }
        profile.embedding = meanEmbedding(profile.contributions.map(\.embedding))
        profile.contribution_count = profile.contributions.count
        profile.updated_at = now
    }

    private static func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        var count = Float(0)
        for embedding in embeddings where embedding.count == first.count {
            for index in embedding.indices {
                sum[index] += embedding[index]
            }
            count += 1
        }
        guard count > 0 else { return [] }
        return (try? normalized(sum.map { $0 / count })) ?? []
    }

    private static func requireCompatible(
        _ profile: VoiceProfile,
        model: String,
        dimension: Int
    ) throws {
        guard profile.embedding_model == model, profile.embedding.count == dimension else {
            throw StoreError.incompatibleProfile
        }
    }

    private static func isValid(_ profile: VoiceProfile) -> Bool {
        profile.name.nilIfBlank != nil
            && profile.embedding_model.nilIfBlank != nil
            && VoiceEmbedding.isUsable(profile.embedding)
            && profile.contributions.allSatisfy { VoiceEmbedding.isUsable($0.embedding) }
    }

    private static func normalized(_ embedding: [Float]) throws -> [Float] {
        guard VoiceEmbedding.isUsable(embedding) else { throw StoreError.invalidEmbedding }
        let norm = sqrt(embedding.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw StoreError.invalidEmbedding }
        return embedding.map { Float(Double($0) / norm) }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
