import XCTest
@testable import Harness

final class CanonicaliserTests: XCTestCase {
    func testNormalForm() {
        let cases: [(String, String)] = [
            ("The Dogs", "dog"),
            ("  a   Paper ", "paper"),
            ("an idea", "idea"),
            ("a", "a"),
            ("the", "the"),
            ("parties", "party"),
            ("boxes", "box"),
            ("glasses", "glass"),
            ("bus", "bus"),
            ("analysis", "analysis"),
            ("sam", "sam"),
            ("ana", "ana"),
            ("review", "review"),
            ("meeting notes", "meeting note"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Canonicaliser.canonical(input), expected, input)
        }
    }

    func testResolveAgainstExistingNames() {
        let existing = ["paper", "ana", "manuscript", "review"]
        let cases: [(String, String, Bool)] = [
            ("paper", "paper", true),
            ("Papers", "paper", true),
            ("the paper", "paper", true),
            ("manuscrpt", "manuscript", true),
            ("manuscripts", "manuscript", true),
            ("sam", "sam", false),
            ("ann", "ann", false),      // short names never near-match
            ("reviewer", "review", true), // distance 2 on a long name
            ("The Thesis", "thesis", false),
        ]
        for (input, expected, existingFlag) in cases {
            let r = Canonicaliser.resolve(input, among: existing)
            XCTAssertEqual(r.name, expected, input)
            XCTAssertEqual(r.existing, existingFlag, input)
        }
    }

    func testLikelyDuplicates() {
        let pairs = Canonicaliser.likelyDuplicates(in: ["paper", "papers", "the paper", "manuscript", "manuscrpt", "ana", "ann"])
        XCTAssertTrue(pairs.contains { $0.0 == "paper" && $0.1 == "papers" })
        XCTAssertTrue(pairs.contains { $0.0 == "paper" && $0.1 == "the paper" })
        XCTAssertTrue(pairs.contains { $0.0 == "manuscripts".dropLast() && $0.1 == "manuscrpt" } || pairs.contains { $0.0 == "manuscript" && $0.1 == "manuscrpt" })
        XCTAssertFalse(pairs.contains { $0.0 == "ana" && $0.1 == "ann" })
    }

    func testEditDistance() {
        XCTAssertEqual(Canonicaliser.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(Canonicaliser.editDistance("", "abc"), 3)
        XCTAssertEqual(Canonicaliser.editDistance("same", "same"), 0)
    }
}
