import SwiftUI
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

    // Three animations
    static let arrival = Animation.spring(response: 0.45, dampingFraction: 0.7)
    static let slide = Animation.easeOut(duration: 0.22)
    static let selection = Animation.easeInOut(duration: 0.12)

    /// How long a freshly appended line stays highlighted.
    static let highlightSeconds: TimeInterval = 4
}
