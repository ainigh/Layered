import Foundation
import XCTest
@testable import Harness

enum Fixtures {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw XCTSkip("missing fixture \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

func n(_ name: String, _ scope: String = "") -> NodeID { NodeID(scope: scope, name: name) }

let fixedDate = Date(timeIntervalSince1970: 1_793_196_153) // 2026-10-28T14:02:33Z
