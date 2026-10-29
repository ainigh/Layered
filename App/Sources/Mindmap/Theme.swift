import SwiftUI
import AppKit
import Harness

/// The one set of design tokens (SPEC “Looking nice by construction”). Views use only these.
enum Theme {
    // 4 text sizes
    static let title = Font.system(.title3, design: .rounded).weight(.semibold)
    static let body = Font.system(.body)
    static let caption = Font.system(.caption)
    static let label = Font.system(.footnote, design: .rounded).weight(.medium)

    // 8-pt spacing scale
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // 2 corner radii
    static let radiusSmall: CGFloat = 6
    static let radiusLarge: CGFloat = 12

    static let accent = Color.accentColor

    // Five provenance styles
    struct ProvenanceStyle {
        let dash: [CGFloat]
        let lineWidth: CGFloat
        let doubleBorder: Bool
        let fillOpacity: Double
        let opacity: Double
        let badge: String?
        let tint: Color?
    }

    static func provenance(_ src: String?) -> ProvenanceStyle {
        switch src {
        case "world": return ProvenanceStyle(dash: [6, 4], lineWidth: 1.5, doubleBorder: false, fillOpacity: 0.35, opacity: 0.9, badge: "globe", tint: nil)
        case "guess": return ProvenanceStyle(dash: [2, 3], lineWidth: 1.5, doubleBorder: false, fillOpacity: 0.25, opacity: 0.65, badge: "questionmark", tint: nil)
        case "advice": return ProvenanceStyle(dash: [], lineWidth: 1.5, doubleBorder: true, fillOpacity: 0.6, opacity: 1, badge: "lightbulb", tint: .orange)
        case "user": return ProvenanceStyle(dash: [], lineWidth: 1.5, doubleBorder: false, fillOpacity: 0.6, opacity: 1, badge: "pencil", tint: nil)
        default: return ProvenanceStyle(dash: [], lineWidth: 1.5, doubleBorder: false, fillOpacity: 0.6, opacity: 1, badge: nil, tint: nil)
        }
    }

    // Six node kinds
    static func kind(_ kind: String?) -> Color {
        switch kind {
        case "person": return Color(red: 0.23, green: 0.49, blue: 0.85)
        case "place": return Color(red: 0.16, green: 0.62, blue: 0.56)
        case "thing": return Color(red: 0.42, green: 0.36, blue: 0.91)
        case "action": return Color(red: 0.88, green: 0.48, blue: 0.12)
        case "event": return Color(red: 0.84, green: 0.23, blue: 0.42)
        case "idea": return Color(red: 0.79, green: 0.64, blue: 0.15)
        default: return Color.secondary
        }
    }

    /// Where a context item came from: its colour, symbol and name in the Context panel. The
    /// model's replies take a colour of their own so they never pass for what the user added.
    struct OriginStyle {
        let color: Color
        let symbol: String
        let title: String
    }

    static func origin(_ origin: ContextItem.Origin) -> OriginStyle {
        switch origin {
        case .you: return OriginStyle(color: accent, symbol: "text.cursor", title: "You")
        case .audio: return OriginStyle(color: Color(red: 0.16, green: 0.62, blue: 0.56), symbol: "waveform", title: "Audio")
        case .clarification: return OriginStyle(color: Color(red: 0.88, green: 0.48, blue: 0.12), symbol: "questionmark.bubble", title: "Clarification")
        case .model: return OriginStyle(color: Color(red: 0.58, green: 0.36, blue: 0.86), symbol: "sparkles", title: "Model")
        }
    }

    // Three animations
    static let arrival = Animation.spring(response: 0.45, dampingFraction: 0.7)
    static let slide = Animation.easeOut(duration: 0.22)
    static let selection = Animation.easeInOut(duration: 0.12)

    /// How long a freshly appended line stays highlighted.
    static let highlightSeconds: TimeInterval = 4

    /// The mind map (GridClip's look): colours from the harness's `MapPalette`, light and
    /// dark, and the faces the layout measures with. Sizes in points match `MapLayout.Metrics`.
    enum Map {
        static let background = dynamic(\.background)
        static let dot = dynamic(\.dot)
        static let primary = dynamic(\.textPrimary)
        static let secondary = dynamic(\.textSecondary)
        static let tertiary = dynamic(\.textTertiary)
        static let world = dynamic(\.world)
        static let worldInk = dynamic(\.worldInk)
        static let guess = dynamic(\.guess)
        static let guessInk = dynamic(\.guessInk)
        static let advice = dynamic(\.advice)
        static let adviceInk = dynamic(\.adviceInk)

        /// A card's fill and outline: the model's extras each have their own colours.
        static func cardColours(_ src: String?) -> (fill: Color, ink: Color) {
            switch src {
            case "world": return (world, worldInk)
            case "advice": return (advice, adviceInk)
            default: return (guess, guessInk)
            }
        }
        private static let inks = (0..<MapPalette.light.hues.count).map { i in dynamic { $0.hues[i].ink } }

        /// A first-level branch's colour for its links and outlines; nil for roots and cross-links.
        static func branch(_ n: Int) -> Color? { n > 0 ? inks[(n - 1) % inks.count] : nil }

        static let nameSize: CGFloat = 13
        static let noteSize: CGFloat = 11.5
        /// Edge labels: smaller and lighter than notes, and set in the secondary grey.
        static let labelSize: CGFloat = 10
        /// An open node's icon, twice its name.
        static let iconSize: CGFloat = nameSize * 2
        static let name = Font.system(size: nameSize, weight: .medium)
        static let rootName = Font.system(size: nameSize, weight: .semibold)
        static let note = Font.system(size: noteSize, weight: .medium)
        static let label = Font.system(size: labelSize, weight: .regular)
        static let icon = Font.system(size: iconSize, weight: .regular)
        static let corner: CGFloat = 8
        /// Bounds of the zoom; a fit never zooms a small map in past `maxFit`.
        static let minZoom: CGFloat = 0.1
        static let maxZoom: CGFloat = 3
        static let maxFit: CGFloat = 2
        static let fitPad: CGFloat = 24
        static let zoomStep: CGFloat = 1.4
        /// Spacing of the background dots at zoom 1.
        static let dotGap: CGFloat = 20
        /// Buttons, keys and fit glide; drags and the wheel follow the hand.
        static let glide: TimeInterval = 0.24

        /// Widths as the canvas sets the text, so cards fit their names exactly.
        @MainActor static func measure(_ text: String, _ role: MapLayout.TextRole) -> Double {
            let key = "\(role)\u{1}\(text)"
            if let w = widths[key] { return w }
            let font = NSFont.systemFont(ofSize: role == .name ? nameSize : role == .label ? labelSize : noteSize, weight: role == .label ? .regular : .medium)
            let w = Double(ceil((text as NSString).size(withAttributes: [.font: font]).width))
            if widths.count > 20_000 { widths.removeAll() }
            widths[key] = w
            return w
        }
        @MainActor private static var widths: [String: Double] = [:]

        private static func dynamic(_ hex: @escaping @Sendable (MapPalette) -> String) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: hex(dark ? .dark : .light))
            })
        }
    }
}

extension NSColor {
    /// `#rrggbb`, as the harness's palette writes colours.
    convenience init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
