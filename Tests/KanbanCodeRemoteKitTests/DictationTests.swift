import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Dictation: spoken words join the draft")
struct DictationTests {
    @Test func dictatedWordsJoinTheDraftAtTheCaret() {
        let middle = Dictation.draft(prefix: "Hello", suffix: " world", settled: "there", guessing: "")
        #expect(middle.text == "Hello there world")
        #expect(middle.caret == "Hello there".count)

        let empty = Dictation.draft(prefix: "", suffix: "", settled: "", guessing: "there")
        #expect(empty.text == "there")
        #expect(empty.caret == 5)

        #expect(Dictation.draft(prefix: "Hello ", suffix: "", settled: "there", guessing: "").text == "Hello there")
        #expect(Dictation.draft(prefix: "Hello", suffix: "world", settled: "big", guessing: "").text == "Hello big world")
        #expect(Dictation.draft(prefix: "Hello", suffix: ", world", settled: "there", guessing: "").text == "Hello there, world")
        #expect(Dictation.draft(prefix: "Hi\n", suffix: "", settled: " the invoice", guessing: "run ").text == "Hi\nthe invoice run")
    }

    @Test func guessedWordsJoinTheSettledOnesAndNothingSpokenLeavesTheDraft() {
        #expect(Dictation.join("the invoice", "run") == "the invoice run")
        #expect(Dictation.join("the invoice ", "run") == "the invoice run")
        #expect(Dictation.join("moved", ".") == "moved.")
        #expect(Dictation.join("", "run") == "run")
        let none = Dictation.draft(prefix: "Hello", suffix: " world", settled: "", guessing: "  ")
        #expect(none.text == "Hello world")
        #expect(none.caret == 5)
    }

    @Test func wordsGoAtTheCaretAndNeverReplaceTheTypedText() {
        var insertion = DictationInsertion(text: "Fix the bug in login", selection: 7..<7)
        #expect(insertion.write(settled: "", guessing: "nasty").text == "Fix the nasty bug in login")
        let settled = insertion.write(settled: "nasty old", guessing: "")
        #expect(settled.text == "Fix the nasty old bug in login")
        #expect(settled.caret == "Fix the nasty old".count)
        #expect(insertion.original == "Fix the bug in login")
    }

    @Test func withoutACaretTheWordsGoAtTheEnd() {
        var insertion = DictationInsertion(text: "Run the tests", selection: nil)
        #expect(insertion.write(settled: "and push", guessing: "").text == "Run the tests and push")
        var blank = DictationInsertion(text: "", selection: nil)
        #expect(blank.write(settled: "hello", guessing: "there").text == "hello there")
    }

    @Test func aSelectionIsReplacedAndCancelGivesTheOriginalBack() {
        var insertion = DictationInsertion(text: "Deploy to staging now", selection: 10..<17)
        #expect(insertion.write(settled: "production", guessing: "").text == "Deploy to production now")
        #expect(insertion.original == "Deploy to staging now")
    }

    @Test func aCaretPastTheTextIsClamped() {
        var insertion = DictationInsertion(text: "Hi", selection: 9..<12)
        #expect(insertion.prefix == "Hi")
        #expect(insertion.suffix == "")
        #expect(insertion.write(settled: "there", guessing: "").text == "Hi there")
    }

    @Test func onlyTextDictationDidNotWriteIsTyping() {
        var insertion = DictationInsertion(text: "Hello", selection: nil)
        #expect(!insertion.isTyping("Hello"))
        let written = insertion.write(settled: "world", guessing: "").text
        #expect(!insertion.isTyping(written))
        #expect(insertion.isTyping(written + "!"))
    }

    @Test func dictationDefaultsToTheClosestSupportedLanguage() {
        let supported = ["en_US", "en_GB", "pt_BR", "pt_PT", "fr_FR"]
        #expect(Dictation.localeChoice(preferred: ["en-GB", "pt-BR"], supported: supported, remembered: nil) == "en_GB")
        #expect(Dictation.localeChoice(preferred: ["pt"], supported: ["en_US", "pt_BR"], remembered: nil) == "pt_BR")
        #expect(Dictation.localeChoice(preferred: ["en-GB"], supported: supported, remembered: "pt_BR") == "pt_BR")
        #expect(Dictation.localeChoice(preferred: ["en-GB"], supported: supported, remembered: "de_DE") == "en_GB")
        #expect(Dictation.localeChoice(preferred: ["ja-JP"], supported: ["fr_FR", "en_US"], remembered: nil) == "en_US")
        #expect(Dictation.localeChoice(preferred: ["ja-JP"], supported: ["fr_FR", "de_DE"], remembered: nil) == "fr_FR")
        #expect(Dictation.localeChoice(preferred: ["en-GB"], supported: [], remembered: "en_GB") == nil)
        #expect(Dictation.localeChoice(preferred: ["ja-JP"], keyboard: ["pt-BR"], supported: supported, remembered: nil) == "pt_BR")
        #expect(Dictation.localeChoice(preferred: ["en-GB"], keyboard: ["pt-BR"], supported: supported, remembered: nil) == "en_GB")
    }

    @Test func everyLanguageIsOfferedWithThePreferredOnesFirst() {
        let supported = ["fr_FR", "en_US", "en_GB", "pt_BR", "de_DE"]
        let ordered = Dictation.orderedLocales(preferred: ["en-GB", "pt-BR"], supported: supported)
        #expect(Array(ordered.prefix(2)) == ["en_GB", "pt_BR"])
        #expect(Set(ordered) == Set(supported))
        let rest = ordered.dropFirst(2).map(Dictation.englishName)
        #expect(rest == rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(Dictation.languages(preferred: ["en-GB", "en-gb", "en"], supported: supported) == ["en_GB", "en_US"])
        #expect(Dictation.orderedLocales(preferred: ["en-GB"], supported: []).isEmpty)
    }

    @Test func theLevelMapsDecibelsToTheBars() {
        #expect(Dictation.level(decibels: -80) == 0)
        #expect(abs(Dictation.level(decibels: -35) - 0.5) < 0.0001)
        #expect(Dictation.level(decibels: 0) == 1)
    }

    @Test func aScriptGuessesEachWordThenSettlesIt() {
        let steps = Dictation.script("the invoice run")
        #expect(steps.map(\.settled) == ["", "the", "the invoice"])
        #expect(steps.map(\.guessing) == ["the", "invoice", "run"])
    }

    @Test func theWaitingLineNamesTheModelAndItsDownload() {
        #expect(Dictation.waitingLine(language: "Portuguese (Brazil)", download: nil) == "Loading the voice model…")
        #expect(Dictation.waitingLine(language: "Portuguese (Brazil)", download: 0.4) == "Downloading the Portuguese (Brazil) voice model, 40%")
    }

    @Test func theLevelLineGlidesAndKeepsItsBars() {
        var motion = LevelLineMotion(capacity: 4)
        motion.advance(by: 0.2, towards: 1)
        #expect(motion.live > 0.9)
        #expect(motion.bars.count == 4)
        motion.advance(by: 0.01, towards: 0, still: true)
        #expect(motion.shift == 0)
    }
}
