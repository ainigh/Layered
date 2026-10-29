/// The mind map's colours, light and dark, as hex: the canvas (through the app's `Theme`)
/// and the SVG export read the same values. Ten branch hues (GridClip's board colours:
/// Blue, Violet, Teal, Amber, Rose, Green, Orange, Fuchsia, Olive, Slate), each an ink for
/// lines and outlines and a tint for fills, plus the neutrals the map sits on.
public struct MapPalette: Equatable, Sendable {
    public struct Hue: Equatable, Sendable {
        public let ink: String
        public let tint: String
    }

    public let hues: [Hue]
    /// The map's background and its dot grid.
    public let background: String
    public let dot: String
    public let textPrimary: String
    public let textSecondary: String
    public let textTertiary: String
    /// The cards of the model's extras: a fill and an outline each, so world knowledge,
    /// guesses and advice read apart at a glance.
    public let world: String
    public let worldInk: String
    public let guess: String
    public let guessInk: String
    public let advice: String
    public let adviceInk: String

    /// Branch `n` (1-based, wrapping after ten); nil for roots and cross-links (0).
    public func hue(_ branch: Int) -> Hue? {
        branch > 0 ? hues[(branch - 1) % hues.count] : nil
    }

    public static let light = MapPalette(
        hues: [
            Hue(ink: "#2c5fc0", tint: "#d9e5f7"), Hue(ink: "#6a45c9", tint: "#e4dcf6"),
            Hue(ink: "#137a70", tint: "#d3ece8"), Hue(ink: "#9a5b00", tint: "#f4e6cd"),
            Hue(ink: "#b8355e", tint: "#f5dbe2"), Hue(ink: "#2b7a3d", tint: "#d7eedb"),
            Hue(ink: "#ad4f19", tint: "#f7e0d0"), Hue(ink: "#9e3898", tint: "#f1d9f0"),
            Hue(ink: "#5a6a10", tint: "#e8edcc"), Hue(ink: "#4d5b6e", tint: "#dfe3e8"),
        ],
        background: "#f4f5f8", dot: "#d3d6dd",
        textPrimary: "#151821", textSecondary: "#454c5c", textTertiary: "#6b7282",
        world: "#e3edfb", worldInk: "#3d6fc4", guess: "#eef0f3", guessInk: "#8a909c",
        advice: "#fdf1dc", adviceInk: "#b7791f")

    public static let dark = MapPalette(
        hues: [
            Hue(ink: "#8db4ff", tint: "#0f1a2e"), Hue(ink: "#b9a1ff", tint: "#1a1430"),
            Hue(ink: "#5fd3c4", tint: "#0b2320"), Hue(ink: "#f2b75a", tint: "#281d0b"),
            Hue(ink: "#ff9cb8", tint: "#2a121a"), Hue(ink: "#6fd58a", tint: "#0d2414"),
            Hue(ink: "#ffa36b", tint: "#2a170b"), Hue(ink: "#f08ee8", tint: "#26112a"),
            Hue(ink: "#c4d65a", tint: "#1d200a"), Hue(ink: "#a9b6c8", tint: "#161a20"),
        ],
        background: "#16181d", dot: "#2e313a",
        textPrimary: "#f3f4f7", textSecondary: "#c0c5d0", textTertiary: "#9aa1ae",
        world: "#172338", worldInk: "#8db4ff", guess: "#25272d", guessInk: "#7d8493",
        advice: "#3a2c14", adviceInk: "#f2b75a")
}
