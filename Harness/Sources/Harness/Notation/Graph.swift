/// The compiled graph (notation §4–§5) plus the outline layer from SPEC
/// “Notation extensions” (headings and attached comments).
public struct NodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var scope: String
    public var name: String

    public init(scope: String = "", name: String) {
        self.scope = scope
        self.name = name
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.scope == rhs.scope ? lhs.name < rhs.name : lhs.scope < rhs.scope
    }

    public var description: String { scope.isEmpty ? name : "\(name)@\(scope)" }
}

public struct Node: Equatable, Sendable {
    public var id: NodeID
    public var notes: [String] = []

    public init(id: NodeID, notes: [String] = []) {
        self.id = id
        self.notes = notes
    }

    /// Returns the value of the first note of a kind: `@src text` → `"text"`.
    public func note(kind: String) -> String? {
        notes.lazy.compactMap { NoteKind.split($0) }.first { $0.kind == kind }?.value
    }

    mutating func addNote(_ note: String, singleValued: Set<String>) {
        NoteKind.add(note, to: &notes, singleValued: singleValued)
    }
}

/// Note convention: a note starts with its kind (`date`, `src`, `kind`, …).
public enum NoteKind {
    public static func split(_ note: String) -> (kind: String, value: String)? {
        guard let space = note.firstIndex(of: " ") else { return (note, "") }
        return (String(note[..<space]), String(note[note.index(after: space)...]))
    }

    /// A single-valued kind replaces its earlier value in place, so re-stating the
    /// same value changes nothing (the gate relies on that to spot duplicates).
    static func add(_ note: String, to notes: inout [String], singleValued: Set<String>) {
        if let kind = split(note)?.kind, singleValued.contains(kind),
           let index = notes.firstIndex(where: { split($0)?.kind == kind }) {
            notes[index] = note
            return
        }
        notes.appendUnique(note)
    }
}

/// Identity of an edge: the unordered pair of nodes (§4 “Merge”).
public struct EdgeKey: Hashable, Comparable, Sendable {
    public let lo: NodeID
    public let hi: NodeID

    public init(_ a: NodeID, _ b: NodeID) {
        if a <= b { lo = a; hi = b } else { lo = b; hi = a }
    }

    public static func < (lhs: EdgeKey, rhs: EdgeKey) -> Bool {
        lhs.lo == rhs.lo ? lhs.hi < rhs.hi : lhs.lo < rhs.lo
    }
}

public struct Edge: Equatable, Sendable {
    /// Endpoints in first-seen order.
    public var a: NodeID
    public var b: NodeID
    /// `a → b` and `b → a`. Neither set means undirected.
    public var forward = false
    public var backward = false
    public var labels: [String] = []
    public var notes: [String] = []

    public init(a: NodeID, b: NodeID) {
        self.a = a
        self.b = b
    }

    public var key: EdgeKey { EdgeKey(a, b) }
    public var isUndirected: Bool { !forward && !backward }
    public var isTwoWay: Bool { forward && backward }

    public func note(kind: String) -> String? {
        notes.lazy.compactMap { NoteKind.split($0) }.first { $0.kind == kind }?.value
    }

    mutating func add(from: NodeID, to: NodeID, directed: Bool, labels: [String], notes: [String], singleValued: Set<String>) {
        if directed {
            if from == a && to == b { forward = true } else { backward = true }
        }
        for label in labels { self.labels.appendUnique(label) }
        for note in notes { NoteKind.add(note, to: &self.notes, singleValued: singleValued) }
    }

    mutating func merge(_ other: Edge, singleValued: Set<String>) {
        if other.forward { add(from: other.a, to: other.b, directed: true, labels: [], notes: [], singleValued: singleValued) }
        if other.backward { add(from: other.b, to: other.a, directed: true, labels: [], notes: [], singleValued: singleValued) }
        for label in other.labels { labels.appendUnique(label) }
        for note in other.notes { NoteKind.add(note, to: &notes, singleValued: singleValued) }
    }
}

public enum Attachment: Equatable, Sendable {
    case node(NodeID)
    case edge(EdgeKey)
}

public struct Comment: Equatable, Sendable {
    public var scope: String
    public var text: String
    /// Heading path this comment sits under (SPEC “Outline via comments”).
    public var heading: [String]
    /// Set when the comment directly follows a statement.
    public var attachedTo: Attachment?

    public var isHeading: Bool { text.hasPrefix("#") }
    /// `@turn …` headers are written by the harness and are not part of the map.
    public var isTurnHeader: Bool { text.hasPrefix("@turn ") || text == "@turn" }

    public var headingLevel: Int { text.prefix { $0 == "#" }.count }
    public var headingTitle: String { Text.collapse(text.drop { $0 == "#" }) }
}

public struct Graph: Equatable, Sendable {
    /// Note kinds the app treats as single-valued: a new `@pos` replaces the old one.
    public static let appSingleValuedNoteKinds: Set<String> = ["src", "kind", "icon", "pos"]

    public var scopes: [String] = [""]
    public var currentScope: String = ""
    public var nodes: [NodeID: Node] = [:]
    public var edges: [EdgeKey: Edge] = [:]
    public var comments: [Comment] = []
    public var singleValuedNoteKinds: Set<String>

    private var headingStack: [String] = []
    private var lastStatementTarget: Attachment?

    public init(singleValuedNoteKinds: Set<String> = Graph.appSingleValuedNoteKinds) {
        self.singleValuedNoteKinds = singleValuedNoteKinds
    }

    // MARK: - Queries

    public func node(_ name: String, scope: String = "") -> Node? {
        nodes[NodeID(scope: scope, name: name)]
    }

    public func edge(_ a: String, _ b: String, scope: String = "") -> Edge? {
        edges[EdgeKey(NodeID(scope: scope, name: a), NodeID(scope: scope, name: b))]
    }

    public func edges(touching id: NodeID) -> [Edge] {
        edges.values.filter { $0.a == id || $0.b == id }.sorted { $0.key < $1.key }
    }

    public func degree(of id: NodeID) -> Int { edges(touching: id).count }

    /// Node names in the root scope, sorted. This is the node list sent to the model.
    public var rootNames: [String] {
        nodes.keys.filter { $0.scope.isEmpty }.map(\.name).sorted()
    }

    // MARK: - Applying lines

    /// Applies one line in log order. Throws for unknown scopes (§5).
    public mutating func apply(_ parsed: ParsedLine) throws {
        try apply(parsed.line, number: parsed.number)
    }

    public mutating func apply(_ line: Line, number: Int = 0) throws {
        switch line {
        case .comment(let text):
            applyComment(text)
        case .scope(let scope):
            lastStatementTarget = nil
            try applyScope(scope, number: number)
        case .statement(.edit(let edit)):
            lastStatementTarget = nil
            try applyEdit(edit, number: number)
        case .statement(.path(let path)):
            try applyPath(path, number: number)
        }
    }

    private mutating func applyComment(_ text: String) {
        var comment = Comment(scope: currentScope, text: text, heading: headingStack, attachedTo: nil)
        if comment.isHeading {
            let level = max(1, comment.headingLevel)
            headingStack = Array(headingStack.prefix(level - 1)) + [comment.headingTitle]
            comment.heading = headingStack
        } else if !comment.isTurnHeader {
            comment.attachedTo = lastStatementTarget
        }
        comments.append(comment)
        lastStatementTarget = nil
    }

    private mutating func applyScope(_ scope: ScopeLine, number: Int) throws {
        switch scope {
        case .enter(let name):
            scopes.appendUnique(name)
            currentScope = name
        case .delete(let name):
            removeScope(name)
            if currentScope == name { currentScope = "" }
        case .merge(let from, let into):
            scopes.appendUnique(into)
            for id in nodes.keys.filter({ $0.scope == from }).sorted() {
                rename(id, to: NodeID(scope: into, name: id.name))
            }
            for index in comments.indices where comments[index].scope == from {
                comments[index].scope = into
            }
            removeScope(from)
            if currentScope == from { currentScope = into }
        }
    }

    private mutating func removeScope(_ name: String) {
        for id in nodes.keys.filter({ $0.scope == name }) { remove(id) }
        comments.removeAll { $0.scope == name }
        scopes.removeAll { $0 == name && !$0.isEmpty }
    }

    private mutating func applyEdit(_ edit: Edit, number: Int) throws {
        let old = try resolve(edit.old, number: number)
        if let new = edit.new {
            rename(old, to: try resolve(new, number: number))
        } else {
            remove(old)
        }
    }

    private mutating func applyPath(_ path: Path, number: Int) throws {
        let ids = try path.names.map { try resolve($0, number: number) }
        for id in ids where nodes[id] == nil { nodes[id] = Node(id: id) }
        for (index, link) in path.links.enumerated() {
            addEdge(from: ids[index], to: ids[index + 1], directed: link.directed, labels: link.labels, notes: link.notes)
        }
        let last = ids[ids.count - 1]
        for note in path.notes { nodes[last]!.addNote(note, singleValued: singleValuedNoteKinds) }
        lastStatementTarget = path.links.count == 1 ? .edge(EdgeKey(ids[0], ids[1])) : .node(last)
    }

    private func resolve(_ name: Name, number: Int) throws -> NodeID {
        guard let scope = name.scope else { return NodeID(scope: currentScope, name: name.text) }
        guard scopes.contains(scope) else {
            throw NotationError(line: number, message: "unknown scope `\(scope)` in `\(name.rendered)`; declare it first with `| @ \(scope)`")
        }
        return NodeID(scope: scope, name: name.text)
    }

    // MARK: - Mutations shared by edits and the reducer

    public mutating func addEdge(from: NodeID, to: NodeID, directed: Bool, labels: [String] = [], notes: [String] = []) {
        let key = EdgeKey(from, to)
        var edge = edges[key] ?? Edge(a: from, b: to)
        edge.add(from: from, to: to, directed: directed, labels: labels, notes: notes, singleValued: singleValuedNoteKinds)
        edges[key] = edge
    }

    /// `old = new`: every node equal to `old` becomes `new` (merging if `new` exists),
    /// and comments in the same scope equal to `old` are renamed (§4 “Edits”).
    public mutating func rename(_ old: NodeID, to new: NodeID) {
        if old != new, let node = nodes.removeValue(forKey: old) {
            var target = nodes[new] ?? Node(id: new)
            for note in node.notes { target.addNote(note, singleValued: singleValuedNoteKinds) }
            nodes[new] = target
            for var edge in edges(touching: old) {
                edges.removeValue(forKey: edge.key)
                if edge.a == old { edge.a = new }
                if edge.b == old { edge.b = new }
                if var existing = edges[edge.key] {
                    existing.merge(edge, singleValued: singleValuedNoteKinds)
                    edges[edge.key] = existing
                } else {
                    edges[edge.key] = edge
                }
            }
            for index in comments.indices {
                switch comments[index].attachedTo {
                case .node(old): comments[index].attachedTo = .node(new)
                case .edge(let key) where key.lo == old || key.hi == old:
                    comments[index].attachedTo = .edge(EdgeKey(key.lo == old ? new : key.lo, key.hi == old ? new : key.hi))
                default: break
                }
            }
        }
        for index in comments.indices where comments[index].scope == old.scope && comments[index].text == old.name {
            comments[index].text = new.name
        }
    }

    /// `old =`: the node goes with its edges; comments equal to the text go too.
    public mutating func remove(_ id: NodeID) {
        nodes.removeValue(forKey: id)
        for edge in edges(touching: id) { edges.removeValue(forKey: edge.key) }
        comments.removeAll { ($0.scope == id.scope && $0.text == id.name) }
        for index in comments.indices {
            switch comments[index].attachedTo {
            case .node(id): comments[index].attachedTo = nil
            case .edge(let key) where key.lo == id || key.hi == id: comments[index].attachedTo = nil
            default: break
            }
        }
    }
}

/// Compiles a log into a graph (§4), reporting the first failing line.
public enum Compiler {
    public static func compile(_ source: String, parser: Parser = Parser(), graph: Graph = Graph()) throws -> Graph {
        var graph = graph
        for parsed in try parser.parse(source) {
            try graph.apply(parsed)
        }
        return graph
    }
}
