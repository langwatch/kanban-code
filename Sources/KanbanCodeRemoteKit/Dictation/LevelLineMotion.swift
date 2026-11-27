import Foundation

/// The voice bar's level line over time: the loudness eases towards each new level, a bar is laid
/// every `sample` seconds and the line glides by a fraction of a bar in between, at a steady speed.
/// Same motion on the iPhone and the Mac.
public struct LevelLineMotion: Equatable, Sendable {
    /// How long one bar lasts before the next one is laid down.
    public static let sample = 0.05
    /// Easing time constants: the line rises quickly with the voice and falls back more gently.
    static let rise = 0.045, fall = 0.16
    /// A frame longer than this (the app in the background, a stall) is not played back bar by bar.
    static let longestFrame = 0.25

    /// Laid-down bars, oldest first, each 0 to 1.
    public private(set) var bars: [Double] = []
    /// The live loudness the newest bar grows with, 0 to 1.
    public private(set) var live = 0.0
    /// How far the line has glided towards the next bar, 0 (just laid) to below 1.
    public private(set) var shift = 0.0
    public var capacity: Int

    public init(capacity: Int) { self.capacity = capacity }

    /// Moves the line on by `elapsed` seconds towards `target`. With `still` (reduced motion) it does
    /// not scroll: only the live loudness eases.
    public mutating func advance(by elapsed: Double, towards target: Double, still: Bool = false) {
        let dt = min(max(elapsed, 0), Self.longestFrame)
        let goal = Self.clamped(target)
        let tau = goal > live ? Self.rise : Self.fall
        live += (goal - live) * (1 - exp(-dt / tau))
        if abs(goal - live) < 0.004 { live = goal }
        guard !still else {
            shift = 0
            return
        }
        var moved = shift + dt / Self.sample
        while moved >= 1 {
            bars.append(live)
            moved -= 1
        }
        if bars.count > capacity { bars.removeFirst(bars.count - max(capacity, 0)) }
        shift = moved
    }

    /// The bars to draw, newest first: its level and its distance from the right edge in bars. The
    /// live bar enters at the edge and every bar glides by the same shift, so none ever jumps.
    public var drawn: [(level: Double, offset: Double)] {
        var result = [(level: live, offset: shift)]
        for (age, level) in bars.reversed().enumerated() {
            result.append((level: level, offset: Double(age + 1) + shift))
        }
        return result
    }

    /// A bar's drawn height in points: a dot when silent, up to `tallest` when loud.
    public static func barHeight(level: Double, tallest: Double) -> Double {
        let dot = 2.0
        return dot + (tallest - dot) * pow(clamped(level), 0.85)
    }

    /// With reduced motion the line stands still and its bars follow the loudness in this shape.
    public static func stillShape(_ index: Int) -> Double {
        0.45 + 0.55 * abs(sin(Double(index) * 0.9 + 0.4))
    }

    static func clamped(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
}
