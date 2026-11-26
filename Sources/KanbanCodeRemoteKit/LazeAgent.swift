import Foundation

/// Who created a card. Cards the human made by hand (the Mac's or the
/// phone's New Task, a CLI in his own terminal) are `human`; subagent
/// cards, tasks an agent started over the API or from inside a card's
/// session, and tasks from agent-scope devices (Laze) are `agent`.
public enum CardOrigin: String, Codable, Sendable, Equatable, CaseIterable {
    case human
    case agent

    /// Anything other than `human` reads as an agent, so a newer kind of
    /// agent origin never shows up as the human's.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == CardOrigin.human.rawValue ? .human : .agent
    }
}

/// The Laze agent that listens in a card's session: its id, its name as
/// Laze has it now, and what its face looks like.
public struct RemoteLazeAgent: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// Seed of the generated face (Laze's `sloth:<seed>`, else the agent id).
    public var faceSeed: String
    /// An uploaded picture, as a link Laze signed; it may expire, the
    /// master refreshes it.
    public var imageUrl: String?
    /// A face that is one emoji.
    public var emoji: String?

    public init(id: String, name: String, faceSeed: String? = nil, imageUrl: String? = nil, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.faceSeed = faceSeed ?? id
        self.imageUrl = imageUrl
        self.emoji = emoji
    }
}

/// Laze's generated faces (packages/design-system face.ts), the same seed
/// math as the Laze apps, so an agent looks the same in Kanban Code.
public enum LazeFaces {
    public enum Hue: String, CaseIterable, Sendable {
        case moss, apricot, sky, rose, butter, lilac

        /// `--color-hue-*` in light and dark, as 0xRRGGBB.
        public var light: UInt32 {
            switch self {
            case .moss: 0xA9C29B
            case .apricot: 0xEFB994
            case .sky: 0xA4C3E0
            case .rose: 0xE3AAB6
            case .butter: 0xE9D38A
            case .lilac: 0xBDB0E4
            }
        }

        public var dark: UInt32 {
            switch self {
            case .moss: 0x6F8F61
            case .apricot: 0xC4825A
            case .sky: 0x658FB5
            case .rose: 0xB67381
            case .butter: 0xB89D4C
            case .lilac: 0x8677B5
            }
        }
    }

    /// A stable 32-bit hash over the seed's UTF-16 units, as `seedHash`.
    public static func seedHash(_ seed: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in seed.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        hash ^= hash >> 16
        hash = hash &* 0x85EB_CA6B
        hash ^= hash >> 13
        hash = hash &* 0xC2B2_AE35
        hash ^= hash >> 16
        return hash
    }

    /// The hue of a name's disc, as `hueFor`.
    public static func hue(for seed: String) -> Hue {
        let order: [Hue] = [.moss, .apricot, .sky, .rose, .butter, .lilac]
        return order[Int(seedHash(seed) % UInt32(order.count))]
    }

    /// Numbers in [0, 1) from a seed, the xorshift sequence of `randomOf`.
    struct Random {
        var state: UInt32

        init(_ seed: String) {
            let hash = LazeFaces.seedHash(seed)
            state = hash == 0 ? 1 : hash
        }

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state % 1000) / 1000
        }
    }

    /// Eight outline points around (50, 50) on a 100 unit box.
    public static func blobPoints(_ seed: String, min: Double, spread: Double) -> [(x: Double, y: Double)] {
        var random = Random(seed)
        return (0 ..< 8).map { index in
            let angle = Double(index) / 8 * .pi * 2
            let radius = min + random.next() * spread
            return (50 + cos(angle) * radius, 50 + sin(angle) * radius)
        }
    }
}

/// Everything a seed decides about an agent's sloth, as `slothLookOf`.
public struct LazeSlothLook: Equatable, Sendable {
    public enum Patch: String, CaseIterable, Sendable { case teardrop, round, stripe }
    public enum Eyes: String, CaseIterable, Sendable { case open, happy, sleepy }

    public let fur: LazeFaces.Hue
    public let patch: Patch
    public let eyes: Eyes
    /// Degrees the face leans, from -7 to 7.
    public let tilt: Int
    public let blush: Bool
    public let tuft: Bool
    public let seed: String

    /// The fur order of `SLOTH_FURS`, which differs from the disc hues.
    static let furs: [LazeFaces.Hue] = [.apricot, .butter, .moss, .rose, .lilac, .sky]

    public init(seed: String) {
        var random = LazeFaces.Random("sloth:\(seed)")
        func pick<T>(_ items: [T]) -> T { items[Int((random.next() * Double(items.count)).rounded(.down))] }
        fur = pick(Self.furs)
        patch = pick(Patch.allCases)
        eyes = pick(Eyes.allCases)
        // Math.round: halves go up, so -2.5 becomes -2.
        tilt = Int(((random.next() * 2 - 1) * 7 + 0.5).rounded(.down))
        blush = random.next() < 0.6
        tuft = random.next() < 0.5
        self.seed = seed
    }

    /// The head's eight outline points on the 100 unit box.
    public var headPoints: [(x: Double, y: Double)] { LazeFaces.blobPoints(seed, min: 43, spread: 5) }
}

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension LazeFaces.Hue {
    /// The hue in the current appearance.
    public var color: Color {
        func rgb(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
        }
        let (lr, lg, lb) = rgb(light)
        let (dr, dg, db) = rgb(dark)
        #if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: 1)
                : UIColor(red: lr, green: lg, blue: lb, alpha: 1)
        })
        #else
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: dr, green: dg, blue: db, alpha: 1)
                : NSColor(red: lr, green: lg, blue: lb, alpha: 1)
        })
        #endif
    }
}

/// A Laze agent's face in a circle: its uploaded picture, its emoji, or
/// its generated sloth, as Laze draws them.
public struct LazeAgentAvatar: View {
    public let agent: RemoteLazeAgent
    public var size: CGFloat

    public init(agent: RemoteLazeAgent, size: CGFloat = 14) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        Group {
            if let url = agent.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        drawn
                    }
                }
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    @ViewBuilder private var drawn: some View {
        if let emoji = agent.emoji {
            LazeFaces.hue(for: agent.name).color.opacity(0.35)
                .overlay { Text(emoji).font(.system(size: size * 0.62)) }
        } else {
            LazeSlothFace(look: LazeSlothLook(seed: agent.faceSeed))
        }
    }
}

/// Laze's seeded sloth (face.ts) drawn on a 100 unit box.
public struct LazeSlothFace: View {
    public let look: LazeSlothLook

    private static let mask = Color(red: 1, green: 0xF3 / 255, blue: 0xE2 / 255)
    private static let dark = Color(red: 0x3A / 255, green: 0x2A / 255, blue: 0x33 / 255)
    private static let pupil = Color(red: 0x1C / 255, green: 0x12 / 255, blue: 0x18 / 255)

    public init(look: LazeSlothLook) { self.look = look }

    public var body: some View {
        let fur = look.fur.color
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.scaleBy(x: scale, y: scale)
            if look.tuft {
                var tuft = Path()
                tuft.move(to: CGPoint(x: 38, y: 14))
                tuft.addCurve(to: CGPoint(x: 48, y: 8), control1: CGPoint(x: 37, y: 5), control2: CGPoint(x: 45, y: 1))
                tuft.addCurve(to: CGPoint(x: 58, y: 7), control1: CGPoint(x: 49, y: 0), control2: CGPoint(x: 58, y: -1))
                tuft.addCurve(to: CGPoint(x: 64, y: 14), control1: CGPoint(x: 62, y: 3), control2: CGPoint(x: 67, y: 6))
                tuft.closeSubpath()
                context.fill(tuft, with: .color(fur))
            }
            context.fill(Self.head(look), with: .color(fur))
            var face = context
            face.translateBy(x: 50, y: 55)
            face.rotate(by: .degrees(Double(look.tilt)))
            face.translateBy(x: -50, y: -55)
            face.fill(Path(ellipseIn: CGRect(x: 17, y: 32, width: 66, height: 50)), with: .color(Self.mask))
            for side in [CGFloat(1), -1] {
                face.fill(Self.patch(look.patch, side: side), with: .color(Self.dark))
            }
            for x in [CGFloat(37), 63] { Self.eye(look.eyes, x: x, in: &face) }
            if look.blush {
                for x in [CGFloat(26), 74] {
                    face.fill(
                        Path(ellipseIn: CGRect(x: x - 4.2, y: 60.8, width: 8.4, height: 8.4)),
                        with: .color(Color(red: 0xF0 / 255, green: 0x8A / 255, blue: 0xA0 / 255).opacity(0.5)))
                }
            }
            face.fill(Path(ellipseIn: CGRect(x: 45.2, y: 58.7, width: 9.6, height: 6.6)), with: .color(Self.dark))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 44.5, y: 67.5))
            mouth.addQuadCurve(to: CGPoint(x: 55.5, y: 67.5), control: CGPoint(x: 50, y: 72.5))
            face.stroke(mouth, with: .color(Self.dark), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    private static func head(_ look: LazeSlothLook) -> Path {
        let points = look.headPoints.map { CGPoint(x: $0.x, y: $0.y) }
        func at(_ index: Int) -> CGPoint { points[(index + points.count) % points.count] }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(at(-1), at(0)))
        for index in points.indices {
            path.addQuadCurve(to: mid(at(index), at(index + 1)), control: at(index))
        }
        path.closeSubpath()
        return path
    }

    private static func patch(_ patch: LazeSlothLook.Patch, side: CGFloat) -> Path {
        let mirror = side == 1 ? CGAffineTransform.identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> Path {
            let turn = CGAffineTransform(translationX: cx, y: cy).rotated(by: degrees * .pi / 180)
                .translatedBy(x: -cx, y: -cy)
            return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                .applying(turn).applying(mirror)
        }
        switch patch {
        case .round: return ellipse(cx: 35.5, cy: 53, rx: 11.5, ry: 9, degrees: -16)
        case .stripe: return ellipse(cx: 35, cy: 54, rx: 14, ry: 7, degrees: -24)
        case .teardrop:
            var path = Path()
            path.move(to: CGPoint(x: 44, y: 47))
            path.addCurve(to: CGPoint(x: 25.5, y: 51), control1: CGPoint(x: 39, y: 42), control2: CGPoint(x: 28, y: 43))
            path.addCurve(to: CGPoint(x: 35.5, y: 61), control1: CGPoint(x: 23, y: 59.5), control2: CGPoint(x: 30, y: 65))
            path.addCurve(to: CGPoint(x: 44, y: 47), control1: CGPoint(x: 40, y: 57.5), control2: CGPoint(x: 45, y: 53.5))
            path.closeSubpath()
            return path.applying(mirror)
        }
    }

    private static func eye(_ eyes: LazeSlothLook.Eyes, x: CGFloat, in context: inout GraphicsContext) {
        switch eyes {
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: x - 4.2, y: 53))
            arc.addQuadCurve(to: CGPoint(x: x + 4.2, y: 53), control: CGPoint(x: x, y: 47.5))
            context.stroke(arc, with: .color(mask), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        case .sleepy:
            // The lower half of each circle: the lid is closed over the top.
            var white = Path()
            white.addArc(center: CGPoint(x: x, y: 51), radius: 4.2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            white.closeSubpath()
            context.fill(white, with: .color(.white))
            var dot = Path()
            dot.addArc(center: CGPoint(x: x + 0.2, y: 51), radius: 2.6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            dot.closeSubpath()
            context.fill(dot, with: .color(pupil))
        case .open:
            context.fill(Path(ellipseIn: CGRect(x: x - 4.4, y: 47.6, width: 8.8, height: 8.8)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: x + 0.6 - 2.9, y: 49.7, width: 5.8, height: 5.8)), with: .color(pupil))
            context.fill(Path(ellipseIn: CGRect(x: x + 0.6, y: 50.2, width: 2, height: 2)), with: .color(.white))
        }
    }
}

/// The agent's face and name, the first item of a card's metadata line.
public struct LazeAgentLabel: View {
    public let agent: RemoteLazeAgent
    public var faceSize: CGFloat

    public init(agent: RemoteLazeAgent, faceSize: CGFloat = 14) {
        self.agent = agent
        self.faceSize = faceSize
    }

    public var body: some View {
        HStack(spacing: 4) {
            LazeAgentAvatar(agent: agent, size: faceSize)
            Text(agent.name)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Laze agent \(agent.name)")
    }
}
#endif
