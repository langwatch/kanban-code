import Foundation

/// The composer's dictation text rules: how spoken words join the draft, which languages the
/// microphone offers, and how loud the level bars are. Shared by the iPhone and Mac composers.
public enum Dictation {
    /// The draft with the dictated words between the text before and after the caret, and the
    /// caret (in characters) right after the dictated words.
    public static func draft(prefix: String, suffix: String, settled: String, guessing: String) -> (text: String, caret: Int) {
        let spoken = join(settled, guessing).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return (prefix + suffix, prefix.count) }
        let lead = prefix.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trail = suffix.first.map { $0.isWhitespace || $0.isPunctuation ? "" : " " } ?? ""
        let head = prefix + lead + spoken
        return (head + trail + suffix, head.count)
    }

    /// Two runs of words with one space between them, none before punctuation.
    public static func join(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else { return first + second }
        if last.isWhitespace || next.isWhitespace || next.isPunctuation { return first + second }
        return first + " " + second
    }

    /// The preferred languages the engine supports, in preference order, as the engine's own
    /// identifiers: an exact match first, else the first supported locale of the same language.
    public static func languages(preferred: [String], supported: [String]) -> [String] {
        let engine = supported.map(normalised)
        var offered: [String] = []
        for language in preferred.map(normalised) {
            let exact = engine.first { $0.lowercased() == language.lowercased() }
            let code = languageCode(language)
            guard let match = exact ?? engine.first(where: { languageCode($0) == code }) else { continue }
            if !offered.contains(match) { offered.append(match) }
        }
        return offered
    }

    /// Every supported locale: the preferred languages' matches first, then the rest by name.
    public static func orderedLocales(
        preferred: [String], supported: [String], name: (String) -> String = englishName
    ) -> [String] {
        let first = languages(preferred: preferred, supported: supported)
        var rest: [String] = []
        for locale in supported.map(normalised) where !first.contains(locale) && !rest.contains(locale) {
            rest.append(locale)
        }
        return first + rest.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The locale dictation listens in: the remembered one while supported, else the closest
    /// match to the system languages, then the keyboards' languages, else en_US, else the first.
    public static func localeChoice(
        preferred: [String], keyboard: [String] = [], supported: [String], remembered: String?
    ) -> String? {
        let engine = supported.map(normalised)
        if let remembered = remembered.map(normalised), engine.contains(remembered) { return remembered }
        return languages(preferred: preferred, supported: supported).first
            ?? languages(preferred: keyboard, supported: supported).first
            ?? engine.first { $0 == "en_US" }
            ?? engine.first
    }

    /// The voice bar's line while a stop waits for the model: its download, else its loading.
    public static func waitingLine(language: String, download: Double?) -> String {
        guard let download else { return "Loading the voice model…" }
        return "Downloading the \(language) voice model, \(Int((download * 100).rounded()))%"
    }

    public static func englishName(_ identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Loudness in decibels as 0 to 1: -55 dB and below is silence, -15 dB and above is loud.
    public static func level(decibels: Double) -> Double {
        min(max((decibels + 55) / 40, 0), 1)
    }

    /// One step of a scripted dictation, as the UI tests' stand-in engine plays it.
    public struct ScriptStep: Equatable, Sendable {
        public let settled: String
        public let guessing: String
        public let level: Double
    }

    /// Each word is guessed first and settles when the next one is heard.
    public static func script(_ text: String) -> [ScriptStep] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.indices.map { index in
            ScriptStep(
                settled: words[..<index].joined(separator: " "), guessing: words[index],
                level: 0.35 + 0.5 * abs(sin(Double(index + 1))))
        }
    }

    public static func normalised(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_")
    }

    static func languageCode(_ identifier: String) -> String {
        String(identifier.split(separator: "_").first ?? "").lowercased()
    }
}

/// One dictation into a draft: the text before and after the caret when it started, so spoken
/// words go between them and never replace what was typed. A change to the draft that dictation
/// did not write is typing, which ends the dictation.
public struct DictationInsertion: Equatable, Sendable {
    /// The draft when dictation started, put back on cancel.
    public let original: String
    public let prefix: String
    public let suffix: String
    /// The draft as dictation last wrote it.
    public private(set) var written: String

    /// `selection` is the caret or selected range in characters; a selection is replaced by the
    /// spoken words. Without a caret the words go at the end.
    public init(text: String, selection: Range<Int>?) {
        original = text
        let count = text.count
        if let selection {
            let lower = min(max(selection.lowerBound, 0), count)
            let upper = min(max(selection.upperBound, lower), count)
            let start = text.index(text.startIndex, offsetBy: lower)
            let end = text.index(text.startIndex, offsetBy: upper)
            prefix = String(text[..<start])
            suffix = String(text[end...])
        } else {
            prefix = text
            suffix = ""
        }
        written = text
    }

    /// The draft with the words heard so far, and the caret after them.
    public mutating func write(settled: String, guessing: String) -> (text: String, caret: Int) {
        let draft = Dictation.draft(prefix: prefix, suffix: suffix, settled: settled, guessing: guessing)
        written = draft.text
        return draft
    }

    /// The draft changed to something dictation did not write.
    public func isTyping(_ text: String) -> Bool { text != written }
}
