/// On-device vector recall, with the existing meaning scorer as a fallback (#309).
extension CoreEngine {
    func meaningScorer(for question: String) async -> (any MeaningScorer)? {
        let notes = memory.notes.filter { $0.kind != .preference && $0.origin != .quarantined }.map(\.text)
        var seen: Set<String> = []
        let candidates = (notes + memory.exchanges.map(\.owner)).filter { seen.insert($0).inserted }
        // The question is always refreshed, even when it is also a cached candidate.
        let texts = candidates.filter { meaningVectors[$0] == nil } + [VectorMeaning.queryPrefix + question]
        guard let embedded = await model.embed(texts), embedded.count == texts.count,
              let questionVector = embedded.last
        else { return meaning }

        for (text, vector) in zip(texts, embedded) {
            meaningVectors[text] = vector
        }
        let vectors = meaningVectors.filter { seen.contains($0.key) }
        // A full reset keeps the cache bounded without retaining a second copy of memory's text keys.
        if meaningVectors.count > 2000 {
            meaningVectors.removeAll()
        }
        return VectorMeaning(question: questionVector, vectors: vectors)
    }
}
