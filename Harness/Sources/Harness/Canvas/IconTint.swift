/// A colour some words in a node's name give its icons: red for what is urgent or dangerous,
/// orange for a warning or a deadline, green for what is done or going well, and so on. A
/// colour's own name counts too ("red flag"). A name with words of several colours takes the
/// most pressing (red, then orange, then the rest in order); one with none keeps the icon's
/// usual colour (its kind's, or its branch's).
public enum IconTint: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, gray

    /// The words for each colour, singular (names are matched after singularising).
    static let words: [IconTint: Set<String>] = [
        .red: ["red", "crimson", "scarlet", "urgent", "urgency", "danger", "dangerous", "critical", "emergency", "error",
               "fail", "failure", "failed", "fatal", "severe", "blocker", "blocked", "blocking", "bug", "crash", "broken",
               "incident", "outage", "crisis", "threat", "hazard", "stop", "asap", "fire", "panic", "alarm", "attack", "breach"],
        .orange: ["orange", "amber", "warning", "warn", "caution", "risk", "risky", "important", "priority", "deadline",
                  "overdue", "late", "delay", "delayed", "issue", "problem", "concern", "escalation", "escalate", "attention"],
        .yellow: ["yellow", "gold", "golden", "idea", "maybe", "draft", "wip", "tentative", "pending", "todo", "review",
                  "progress", "question", "unsure", "unknown", "highlight"],
        .green: ["green", "done", "complete", "completed", "finished", "success", "successful", "approved", "approve",
                 "ok", "okay", "good", "great", "healthy", "safe", "resolved", "fixed", "pass", "passed", "win", "won",
                 "profit", "growth", "ready", "launched", "shipped", "eco", "sustainable"],
        .blue: ["blue", "navy", "info", "information", "note", "fyi", "plan", "planned", "calm", "trust", "water", "ocean",
                "sky", "cold", "reference", "doc", "documentation"],
        .purple: ["purple", "violet", "lilac", "creative", "creativity", "magic", "dream", "vision", "royal", "mystery",
                  "experiment", "experimental", "ai", "research"],
        .pink: ["pink", "rose", "love", "loved", "heart", "favorite", "favourite", "romance", "romantic", "sweet", "cute"],
        .gray: ["gray", "grey", "silver", "archived", "archive", "deprecated", "obsolete", "cancelled", "canceled",
                "inactive", "paused", "hold", "parked", "dormant", "retired", "legacy", "someday"],
    ]

    /// The colour a name's words give its icons, if any.
    public static func of(_ name: String) -> IconTint? {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map { Canonicaliser.singular(String($0)) })
        return allCases.first { !(words[$0] ?? []).isDisjoint(with: tokens) }
    }
}
