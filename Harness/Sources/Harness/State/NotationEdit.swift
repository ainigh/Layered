import Foundation

/// The notation drawer: the map as its canonical text, which the user edits. What the text
/// says is compiled; the lines that take the map there are appended as a user turn, so the
/// log stays append-only and undo works. Text that does not compile changes nothing and
/// reports the line and why.
public enum NotationEdit {
    /// The graph the text describes, or the first line that does not compile.
    public static func compile(_ text: String) -> Result<Graph, NotationError> {
        do {
            return .success(try Compiler.compile(text))
        } catch let error as NotationError {
            return .failure(error)
        } catch {
            return .failure(NotationError(line: 0, message: "\(error)"))
        }
    }

    /// The lines that take `base` (the map the text was taken from) to `target` (what the
    /// text now says); empty when they already match. Applied to the current map, so what
    /// changed there since `base` (a model's lines while the user typed) stays.
    public static func lines(from base: Graph, to target: Graph) -> [String] {
        Canonical.render(base) == Canonical.render(target) ? [] : Transition.lines(from: base, to: target)
    }
}
