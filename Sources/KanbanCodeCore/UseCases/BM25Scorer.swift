import Foundation

/// BM25 full-text search scoring for session .jsonl files.
public enum BM25Scorer {

    /// BM25 parameters.
    public static let k1: Double = 1.2
    public static let b: Double = 0.4

    /// Score a document against query terms.
    /// - Parameters:
    ///   - terms: Query terms (lowercased, split by whitespace)
    ///   - documentTokens: Tokens from the document (lowercased words)
    ///   - avgDocLength: Average document length across corpus
    ///   - docCount: Total number of documents
    ///   - docFreqs: Number of documents containing each term
    ///   - recencyBoost: Multiplier for document recency (1.0 = no boost)
    public static func score(
        terms: [String],
        documentTokens: [String],
        avgDocLength: Double,
        docCount: Int,
        docFreqs: [String: Int],
        recencyBoost: Double = 1.0
    ) -> Double {
        let docLength = Double(documentTokens.count)
        guard docLength > 0, avgDocLength > 0 else { return 0 }

        // Build term frequency map for the document
        var tf: [String: Int] = [:]
        for token in documentTokens {
            tf[token, default: 0] += 1
        }

        var totalScore = 0.0

        for term in terms {
            // Count both exact matches and prefix matches
            let termFreq: Int
            let dfCount: Int

            // Check for prefix match
            if term.count >= 3 {
                let matchingTokens = documentTokens.filter { $0.hasPrefix(term) }
                termFreq = matchingTokens.count
                dfCount = docFreqs.filter { $0.key.hasPrefix(term) }.values.reduce(0, +)
            } else {
                termFreq = tf[term] ?? 0
                dfCount = docFreqs[term] ?? 0
            }

            guard termFreq > 0 else { continue }

            // IDF component
            let n = Double(docCount)
            let df = max(Double(dfCount), 0.5)
            let idf = log((n - df + 0.5) / (df + 0.5) + 1)

            // TF component with BM25 normalization
            let tfNorm = (Double(termFreq) * (k1 + 1)) /
                (Double(termFreq) + k1 * (1 - b + b * docLength / avgDocLength))

            totalScore += idf * tfNorm
        }

        return totalScore * recencyBoost
    }

    /// Calculate recency boost based on file modification time.
    /// Recent files get a stronger boost (up to 3x for today, decaying over 30 days).
    public static func recencyBoost(modifiedTime: Date) -> Double {
        let daysAgo = Date.now.timeIntervalSince(modifiedTime) / 86400
        if daysAgo <= 0 { return 3.0 }
        if daysAgo >= 30 { return 1.0 }
        // Linear decay from 3.0 to 1.0 over 30 days
        return 3.0 - (2.0 * daysAgo / 30.0)
    }

    /// Tokenize text into lowercase words.
    public static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }
}
