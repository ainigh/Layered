/// The GBNF grammar from notation §8, tightened for a small model (SPEC “Decoding”):
/// one label per link, two notes per path, no scope lines, and the `name` rule
/// rebuilt per request as an alternation of the current node names plus one free branch.
/// `allowDeletes` lets an edit have no right side (`| old =`); `allowEmpty` lets the
/// model answer with no lines at all.
public enum Grammar {
    public static func build(nodes: [String], allowEdits: Bool, allowDeletes: Bool = false, allowComments: Bool = false, allowEmpty: Bool = false) -> String {
        let alternatives = nodes
            .filter { !$0.isEmpty }
            .sorted()
            .map { "\"\(escape($0))\"" }
        let known = alternatives.isEmpty ? "" : alternatives.joined(separator: " | ") + " | "
        var lines: [String] = []
        lines.append("root  ::= line\(allowEmpty ? "*" : "+")")
        let forms = (allowEdits ? "path | edit" : "path") + (allowComments ? " | comment" : "")
        lines.append("line  ::= (\"| \" (\(forms)) \"\\n\")\(allowComments ? " | (comment \"\\n\")" : "")")
        if allowComments { lines.append("comment ::= [^|\\n] [^\\n]*") }
        lines.append("path  ::= name (link name)* note? note?")
        lines.append("link  ::= seg? term")
        lines.append("seg   ::= \" - \" text | note")
        lines.append("note  ::= \" @\" text")
        lines.append("term  ::= \" | \" | \" - | \"")
        if allowEdits { lines.append(allowDeletes ? "edit  ::= name \" =\" (\" \" name)?" : "edit  ::= name \" = \" name") }
        lines.append("name  ::= \(known)free")
        lines.append("free  ::= word (\" \" word)*")
        lines.append("text  ::= word (\" \" word)*")
        lines.append("word  ::= [^ \\n|@=-] [^ \\n@]*")
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
