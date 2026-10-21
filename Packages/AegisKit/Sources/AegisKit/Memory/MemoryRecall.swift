// Reciprocal rank fusion ported from Hindsight (vectorize-io/hindsight on GitHub),
// hindsight_api/engine/search/fusion.py (cap_per_source, reciprocal_rank_fusion), Copyright Vectorize, MIT.
// Changes: translated to Swift; results are plain IDs; ties keep their first appearance.
import Foundation

/// How related a note is to the owner's question by meaning (#305), from 0 to 1, or nil when the two aren't
/// related. Implemented on the Mac with an on-device model; Linux and tests may leave it out.
public protocol MeaningScorer: Sendable {
    func relatedness(_ question: String, _ note: String) -> Double?
}

/// Scores notes against one question using L2-normalised vectors from the on-device embedding model (#309).
public struct VectorMeaning: MeaningScorer {
    /// Calibrated on bge-small with synthetic notes (#309): related pairs 0.56 to 0.69, unrelated at most 0.54.
    public static let threshold: Double = 0.55
    /// bge-small's own instruction for short questions searching longer notes; it lifts "car" to "my Mazda…".
    public static let queryPrefix = "Represent this sentence for searching relevant passages: "

    private let question: [Float]
    private let vectors: [String: [Float]]
    private let threshold: Double

    /// Vectors must be L2-normalised and have the same dimensions as the question vector.
    public init(question: [Float], vectors: [String: [Float]], threshold: Double = VectorMeaning.threshold) {
        self.question = question
        self.vectors = vectors
        self.threshold = threshold
    }

    /// Ignores the question string: this scorer always uses the question vector supplied at initialisation.
    /// Returns nil for missing or incompatible vectors, non-finite scores, or scores below the threshold.
    public func relatedness(_: String, _ note: String) -> Double? {
        guard let vector = vectors[note], !question.isEmpty, vector.count == question.count else { return nil }
        let score = zip(question, vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return score.isFinite && score >= threshold ? score : nil
    }
}

/// Merges ranked lists the way Hindsight's recall does: each list is cut to its best `cap`, then an item scores
/// the sum of 1 / (k + rank) over every list it appears in.
public enum RankFusion {
    public static func fuse(_ lists: [[String]], k: Double = 60, cap: Int = 50) -> [String] {
        var scores: [String: Double] = [:]
        var order: [String] = []
        for list in lists {
            for (index, id) in list.prefix(cap > 0 ? cap : list.count).enumerated() {
                if scores[id] == nil {
                    order.append(id)
                }
                scores[id, default: 0] += 1 / (k + Double(index + 1))
            }
        }
        return order.enumerated().sorted { lhs, rhs in
            let (left, right) = (scores[lhs.element] ?? 0, scores[rhs.element] ?? 0)
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}
