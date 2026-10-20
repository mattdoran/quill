import Foundation

enum VoiceEmbedding {
    static func isUsable(_ embedding: [Float]) -> Bool {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return false }
        let sum = embedding.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        return sum.isFinite && sum > 0
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, isUsable(lhs), isUsable(rhs) else {
            return -.infinity
        }
        let dot = zip(lhs, rhs).reduce(Double(0)) { $0 + Double($1.0) * Double($1.1) }
        let left = sqrt(lhs.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        let right = sqrt(rhs.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard left.isFinite, right.isFinite, left > 0, right > 0 else { return -.infinity }
        let score = dot / (left * right)
        guard score.isFinite else { return -.infinity }
        return Float(score)
    }

    static func normalized(_ embedding: [Float]) -> [Float] {
        let norm = sqrt(embedding.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { return embedding }
        return embedding.map { Float(Double($0) / norm) }
    }
}
