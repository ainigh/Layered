import Foundation

/// What the model put on the map that the user has not yet accepted or deleted. Every
/// model turn goes on the map straight away; what it added is marked here so the canvas
/// can flag it with ✓ and ✕ in place, instead of asking first in a panel.
///
/// Marked: each node the turn added, and each link it added between nodes that were
/// already there (a new node's links go with it). Only the root scope, which the map draws.
public struct Review: Equatable, Sendable {
    public private(set) var nodes: Set<String> = []
    public private(set) var edges: Set<EdgeKey> = []

    public init(nodes: Set<String> = [], edges: Set<EdgeKey> = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public var isEmpty: Bool { nodes.isEmpty && edges.isEmpty }
    public var count: Int { nodes.count + edges.count }

    /// Marks what `after` has that `before` did not.
    public mutating func mark(from before: Graph, to after: Graph) {
        let added = Set(after.nodes.keys.filter { $0.scope.isEmpty && before.nodes[$0] == nil })
        nodes.formUnion(added.map(\.name))
        for key in after.edges.keys where key.lo.scope.isEmpty && key.hi.scope.isEmpty && before.edges[key] == nil {
            if !added.contains(key.lo), !added.contains(key.hi) { edges.insert(key) }
        }
    }

    public mutating func accept(node name: String) { nodes.remove(name) }
    public mutating func accept(edge key: EdgeKey) { edges.remove(key) }
    public mutating func acceptAll() { nodes = []; edges = [] }

    /// Forgets what is no longer on the map (deleted, renamed, undone).
    public mutating func prune(_ graph: Graph) {
        nodes = nodes.filter { graph.node($0) != nil }
        edges = edges.filter { graph.edges[$0] != nil }
    }

    /// The lines that take these nodes and links (or everything marked) off the map, as one turn.
    public func deletion(in graph: Graph, nodes only: Set<String>? = nil, edges onlyEdges: Set<EdgeKey>? = nil) -> [String] {
        var target = graph
        for name in only ?? nodes { target.remove(NodeID(name: name)) }
        for key in onlyEdges ?? edges { target.edges.removeValue(forKey: key) }
        return Transition.lines(from: graph, to: target)
    }
}
