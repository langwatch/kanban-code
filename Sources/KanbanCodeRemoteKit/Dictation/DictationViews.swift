#if canImport(Speech) && canImport(AVFoundation) && canImport(SwiftUI)
import SwiftUI

/// The language rows of a dictation menu: the person's languages first, then every other one,
/// with a checkmark on the current one and a download mark on those not on this device yet.
public struct DictationLanguageRows: View {
    let languages: ComposerDictation.Languages
    let current: String?
    let pick: (String) -> Void

    public init(languages: ComposerDictation.Languages, current: String?, pick: @escaping (String) -> Void) {
        self.languages = languages
        self.current = current
        self.pick = pick
    }

    public var body: some View {
        if languages.suggested > 0 {
            Section("Your languages") {
                ForEach(languages.all.prefix(languages.suggested), id: \.self) { row($0) }
            }
        }
        Section("All languages") {
            ForEach(languages.all.dropFirst(languages.suggested), id: \.self) { row($0) }
        }
    }

    private func row(_ language: String) -> some View {
        Button { pick(language) } label: {
            if language == current {
                Label(ComposerDictation.name(language), systemImage: "checkmark")
            } else if !languages.installed.contains(language) {
                Label(ComposerDictation.name(language), systemImage: "arrow.down.circle")
            } else {
                Text(ComposerDictation.name(language))
            }
        }
        .accessibilityIdentifier("dictation-language-\(language)")
    }
}

/// The live level line across the voice bar, newest on the right, gliding left at a steady speed as
/// the person speaks; silent, it is a calm dotted line. It draws itself once a frame from the
/// meter, so no level re-renders the composer. With reduced motion it stands still and only the
/// loudness eases.
public struct DictationLevelLine: View {
    let meter: DictationMeter
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var line = LineState()

    public init(meter: DictationMeter, color: Color = .secondary) {
        self.meter = meter
        self.color = color
    }

    /// The motion and its last frame's time, kept by reference so a frame never invalidates the view.
    final class LineState {
        var motion = LevelLineMotion(capacity: 0)
        var last: Date?
    }

    private static let step: CGFloat = 4.5, width: CGFloat = 2.2, tallest: CGFloat = 22

    public var body: some View {
        TimelineView(.animation) { timeline in
            let motion = advance(to: timeline.date)
            Canvas { context, size in
                let still = reduceMotion
                line.motion.capacity = Int(size.width / Self.step) + 2
                for (index, bar) in motion.drawn.enumerated() {
                    let x = size.width - Self.width - CGFloat(bar.offset) * Self.step
                    guard x > -Self.width else { break }
                    let level = bar.level * (still ? LevelLineMotion.stillShape(index) : 1)
                    let height = CGFloat(LevelLineMotion.barHeight(level: level, tallest: Double(Self.tallest)))
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.width / 2), with: .color(color))
                }
            }
            .frame(height: 22)
            .mask(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 1)],
                    startPoint: .leading, endPoint: .trailing))
            .accessibilityElement()
            .accessibilityLabel("Voice level")
            .accessibilityValue("\(Int((motion.live * 100).rounded()))")
            .accessibilityIdentifier("dictation-level")
        }
    }

    private func advance(to date: Date) -> LevelLineMotion {
        let elapsed = line.last.map { date.timeIntervalSince($0) } ?? 0
        line.last = date
        line.motion.advance(by: elapsed, towards: meter.level, still: reduceMotion)
        return line.motion
    }
}
#endif
