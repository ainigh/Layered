/// Parses notation lines (docs/notation-original.md §1–§3).
///
/// The parser accepts everything the GBNF grammar (§8) produces and rejects the
/// documented errors with a line number and an actionable message.
public struct Parser: Sendable {
    public struct Options: Sendable {
        /// Base notation allows scope lines and `name@scope`. The app runs with
        /// scopes off: names are global (SPEC “Reserved scope and names”).
        public var allowScopes: Bool

        public init(allowScopes: Bool = true) {
            self.allowScopes = allowScopes
        }

        public static let base = Options(allowScopes: true)
        public static let strict = Options(allowScopes: false)
    }

    public var options: Options

    public init(options: Options = .base) {
        self.options = options
    }

    /// Parses a whole log. Empty lines are skipped; every other line is returned.
    public func parse(_ source: String) throws -> [ParsedLine] {
        var out: [ParsedLine] = []
        for (number, text) in Text.numberedLines(source) where !text.isEmpty {
            out.append(ParsedLine(number: number, raw: text, line: try parseLine(text, number: number)))
        }
        return out
    }

    /// Parses one trimmed, non-empty line.
    public func parseLine(_ text: String, number: Int = 1) throws -> Line {
        let trimmed = Text.collapse(text)
        guard trimmed.first == "|" else { return .comment(trimmed) }
        let tokens = Parser.tokenize(trimmed.dropFirst())
        if tokens.count >= 2, tokens[0].text.isEmpty, tokens[1].symbol == .at {
            return .scope(try parseScope(tokens, number: number))
        }
        return .statement(try parseStatement(tokens, number: number))
    }

    // MARK: - Tokens

    enum Symbol: Character {
        case pipe = "|", dash = "-", at = "@", eq = "="
    }

    struct Token {
        var symbol: Symbol?
        var text: String
    }

    /// A symbol is active only when preceded by whitespace or first in the line (§2).
    /// The first token has no symbol and holds any leading text.
    static func tokenize(_ body: Substring) -> [Token] {
        var tokens = [Token(symbol: nil, text: "")]
        var previousWasSpace = true
        for ch in body {
            if previousWasSpace, let symbol = Symbol(rawValue: ch) {
                tokens.append(Token(symbol: symbol, text: ""))
            } else {
                tokens[tokens.count - 1].text.append(ch)
            }
            previousWasSpace = ch.isWhitespace
        }
        return tokens.map { Token(symbol: $0.symbol, text: Text.collapse($0.text)) }
    }

    // MARK: - Scope lines

    private func parseScope(_ tokens: [Token], number: Int) throws -> ScopeLine {
        guard options.allowScopes else {
            throw NotationError(line: number, message: "scopes are not used in this map; names are global")
        }
        let name = tokens[1].text
        guard !name.isEmpty else {
            throw NotationError(line: number, message: "`| @` needs a scope name after it")
        }
        switch tokens.count {
        case 2:
            return .enter(name)
        case 3 where tokens[2].symbol == .eq:
            guard tokens[2].text.isEmpty else {
                throw NotationError(line: number, message: "a scope can only be renamed onto another scope: write `| @ \(name) = @ other`")
            }
            return .delete(name)
        case 4 where tokens[2].symbol == .eq && tokens[3].symbol == .at:
            guard tokens[2].text.isEmpty else {
                throw NotationError(line: number, message: "write `| @ \(name) = @ other` with nothing between `=` and `@`")
            }
            guard !tokens[3].text.isEmpty else {
                throw NotationError(line: number, message: "`= @` needs a scope name after it")
            }
            return .merge(from: name, into: tokens[3].text)
        default:
            throw NotationError(line: number, message: "a scope line is `| @ name`, `| @ a = @ b` or `| @ a =`")
        }
    }

    // MARK: - Statements

    private func parseStatement(_ tokens: [Token], number: Int) throws -> Statement {
        let first = try parseName(tokens[0].text, number: number, context: "`|` needs a name after it")
        var names = [first]
        var links: [Link] = []
        var labels: [String] = []
        var notes: [String] = []
        var undirectedMarker = false

        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            switch token.symbol! {
            case .eq:
                guard index == 1 else {
                    throw NotationError(line: number, message: "`=` must come right after the name: `| old = new` or `| old =`")
                }
                guard index == tokens.count - 1 else {
                    throw NotationError(line: number, message: "nothing may follow an edit: `| old = new` is a whole line")
                }
                let new = token.text.isEmpty ? nil : try parseName(token.text, number: number, context: "`=` needs a name after it, or nothing to delete")
                return .edit(Edit(old: first, new: new))

            case .dash:
                if undirectedMarker {
                    throw NotationError(line: number, message: "`- |` must be followed directly by a name; a label cannot come between")
                }
                if token.text.isEmpty {
                    guard index + 1 < tokens.count, tokens[index + 1].symbol == .pipe else {
                        throw NotationError(line: number, message: "`-` needs a label after it, or `|` directly after it for an undirected edge")
                    }
                    undirectedMarker = true
                } else {
                    labels.append(token.text)
                }

            case .at:
                if undirectedMarker {
                    throw NotationError(line: number, message: "`- |` must be followed directly by a name; a note cannot come between")
                }
                guard !token.text.isEmpty else {
                    throw NotationError(line: number, message: "`@` needs note text after it, like `@date 2026-11-03`")
                }
                notes.append(token.text)

            case .pipe:
                let name = try parseName(token.text, number: number, context: "`|` needs a name after it")
                links.append(Link(labels: labels, notes: notes, directed: !undirectedMarker))
                names.append(name)
                labels = []
                notes = []
                undirectedMarker = false
            }
            index += 1
        }

        if undirectedMarker {
            throw NotationError(line: number, message: "`- |` needs a name after it")
        }
        if let label = labels.first {
            throw NotationError(line: number, message: "the label `\(label)` needs a target: add `| name` after it")
        }
        return .path(Path(names: names, links: links, notes: notes))
    }

    private func parseName(_ text: String, number: Int, context: String) throws -> Name {
        guard !text.isEmpty else { throw NotationError(line: number, message: context) }
        guard let at = text.firstIndex(of: "@") else { return Name(text) }
        guard options.allowScopes else {
            throw NotationError(line: number, message: "`\(text)` qualifies a scope; names are global in this map, write `\(text[..<at])`")
        }
        let name = Text.collapse(text[..<at])
        let scope = Text.collapse(text[text.index(after: at)...])
        guard !name.isEmpty else { throw NotationError(line: number, message: "`\(text)` has no name before the `@`") }
        return Name(name, scope: scope)
    }
}
