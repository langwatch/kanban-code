//! BM25 full-text scoring for session transcripts. Direct port of
//! `Sources/KanbanCodeCore/UseCases/BM25Scorer.swift` so search ranks the
//! same way it does on macOS.
//!
//! Includes:
//! - `tokenize` — lowercase + split on non-alphanumeric, drop tokens < 2 chars.
//! - `score` — BM25 with prefix-match expansion for 3+ char terms.
//! - `recency_boost` — multiplies recent docs up to 3x, decaying linearly
//!   over 30 days.

use std::collections::HashMap;

pub const K1: f64 = 1.2;
pub const B: f64 = 0.4;

/// Tokenize text into lowercased words ≥ 2 chars, splitting on any
/// non-alphanumeric character. Matches the macOS implementation.
pub fn tokenize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| s.len() >= 2)
        .map(|s| s.to_string())
        .collect()
}

/// BM25 score of one document against a set of query terms. Terms of length
/// ≥ 3 are also matched as prefixes (so "kanb" hits "kanban") — same heuristic
/// the macOS scorer uses to make partial typing useful.
///
/// `doc_freqs` maps token → number of documents containing it across the
/// corpus. `avg_doc_length` is the corpus mean document length in tokens.
pub fn score(
    terms: &[String],
    document_tokens: &[String],
    avg_doc_length: f64,
    doc_count: usize,
    doc_freqs: &HashMap<String, usize>,
    recency_boost: f64,
) -> f64 {
    let doc_length = document_tokens.len() as f64;
    if doc_length == 0.0 || avg_doc_length == 0.0 {
        return 0.0;
    }

    let mut tf: HashMap<&str, usize> = HashMap::new();
    for token in document_tokens {
        *tf.entry(token.as_str()).or_insert(0) += 1;
    }

    let mut total = 0.0;
    for term in terms {
        let (term_freq, df_count) = if term.len() >= 3 {
            // Prefix expansion: sum tfs and dfs for every token starting with
            // `term`. Slower than exact lookup but lets the user type a stem
            // and still hit forms ("ksuid" / "ksuids" / "ksuidGenerator").
            let tf_sum: usize = tf
                .iter()
                .filter(|(k, _)| k.starts_with(term.as_str()))
                .map(|(_, v)| *v)
                .sum();
            let df_sum: usize = doc_freqs
                .iter()
                .filter(|(k, _)| k.starts_with(term))
                .map(|(_, v)| *v)
                .sum();
            (tf_sum, df_sum)
        } else {
            (
                tf.get(term.as_str()).copied().unwrap_or(0),
                doc_freqs.get(term).copied().unwrap_or(0),
            )
        };
        if term_freq == 0 {
            continue;
        }
        let n = doc_count as f64;
        let df = (df_count as f64).max(0.5);
        let idf = ((n - df + 0.5) / (df + 0.5) + 1.0).ln();
        let tf_norm = (term_freq as f64 * (K1 + 1.0))
            / (term_freq as f64 + K1 * (1.0 - B + B * doc_length / avg_doc_length));
        total += idf * tf_norm;
    }
    total * recency_boost
}

/// Linear recency multiplier from 3.0 (today) → 1.0 (≥30 days old). Doesn't
/// penalise old docs below 1.0 — they just don't get the boost.
pub fn recency_boost(age_secs: i64) -> f64 {
    let days_ago = age_secs as f64 / 86_400.0;
    if days_ago <= 0.0 {
        return 3.0;
    }
    if days_ago >= 30.0 {
        return 1.0;
    }
    3.0 - (2.0 * days_ago / 30.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_lowercases_and_filters_short() {
        assert_eq!(
            tokenize("Hello, WORLD! a 42 fooBar"),
            vec!["hello", "world", "42", "foobar"]
        );
    }

    #[test]
    fn score_zero_for_empty_doc() {
        let s = score(
            &["foo".to_string()],
            &[],
            100.0,
            10,
            &HashMap::new(),
            1.0,
        );
        assert_eq!(s, 0.0);
    }

    #[test]
    fn score_higher_for_matching_term() {
        let docs_with_term: HashMap<String, usize> =
            [("kanban".to_string(), 1)].into_iter().collect();
        let s_match = score(
            &["kanban".to_string()],
            &vec!["kanban".to_string(), "code".to_string()],
            5.0,
            10,
            &docs_with_term,
            1.0,
        );
        let s_no_match = score(
            &["kanban".to_string()],
            &vec!["only".to_string(), "text".to_string()],
            5.0,
            10,
            &docs_with_term,
            1.0,
        );
        assert!(s_match > 0.0);
        assert_eq!(s_no_match, 0.0);
    }

    #[test]
    fn recency_decays_linearly() {
        assert!((recency_boost(0) - 3.0).abs() < 1e-9);
        // Halfway through the window (15 days)
        let mid = recency_boost(15 * 86_400);
        assert!((mid - 2.0).abs() < 1e-9);
        assert!((recency_boost(30 * 86_400) - 1.0).abs() < 1e-9);
        assert!((recency_boost(120 * 86_400) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn prefix_match_kicks_in_for_3plus_chars() {
        let docs: HashMap<String, usize> = [("kanban".to_string(), 1)].into_iter().collect();
        let s = score(
            &["kanb".to_string()],
            &vec!["kanban".to_string(), "code".to_string()],
            5.0,
            10,
            &docs,
            1.0,
        );
        assert!(s > 0.0, "prefix 'kanb' should match 'kanban'");
    }
}
