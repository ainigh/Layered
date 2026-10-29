/// One parsed line of the notation (docs/notation-original.md §3).
public enum Line: Equatable, Sendable {
    case comment(String)
    case scope(ScopeLine)
    case statement(Statement)
}

public enum ScopeLine: Equatable, Sendable {
    /// `| @ name` — switch the current scope.
    case enter(String)
    /// `| @ a = @ b` — move everything in `a` into `b`, remove `a`.
    case merge(from: String, into: String)
    /// `| @ a =` — remove the scope with all its nodes, edges and comments.
    case delete(String)
}

public enum Statement: Equatable, Sendable {
    case path(Path)
    case edit(Edit)
}

/// A name as written: `text`, `text@scope`, or `text@` (root).
public struct Name: Equatable, Hashable, Sendable {
    public var text: String
    /// `nil` = unqualified (current scope); `""` = root; otherwise the scope name.
    public var scope: String?

    public init(_ text: String, scope: String? = nil) {
        self.text = text
        self.scope = scope
    }

    /// Renders the name as written: `text`, `text@scope` or `text@` for root.
    public var rendered: String {
        guard let scope else { return text }
        return "\(text)@\(scope)"
    }
}

/// One link between two names in a path: labels, edge notes and direction.
public struct Link: Equatable, Sendable {
    public var labels: [String]
    public var notes: [String]
    public var directed: Bool

    public init(labels: [String] = [], notes: [String] = [], directed: Bool = true) {
        self.labels = labels
        self.notes = notes
        self.directed = directed
    }
}

/// `Name (Link Name)* Note*` — the trailing notes attach to the last name.
public struct Path: Equatable, Sendable {
    public var names: [Name]
    public var links: [Link]
    public var notes: [String]

    public init(names: [Name], links: [Link] = [], notes: [String] = []) {
        precondition(names.count == links.count + 1, "a path has one more name than links")
        self.names = names
        self.links = links
        self.notes = notes
    }
}

/// `old = new` renames (or merges); `old =` deletes.
public struct Edit: Equatable, Sendable {
    public var old: Name
    public var new: Name?

    public init(old: Name, new: Name?) {
        self.old = old
        self.new = new
    }
}

/// A parsed line with where it came from.
public struct ParsedLine: Equatable, Sendable {
    public var number: Int
    public var raw: String
    public var line: Line
}

/// A parse or compile error with a line number and a message a user can act on.
public struct NotationError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}
