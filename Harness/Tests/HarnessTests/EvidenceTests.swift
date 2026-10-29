import XCTest
@testable import Harness

final class EvidenceTests: XCTestCase {
    func testSentenceSplitting() {
        let cases: [(String, [String])] = [
            ("I'm Sam. I'm writing a paper, Ana reviews it on Nov 3.", ["I'm Sam.", "I'm writing a paper, Ana reviews it on Nov 3."]),
            ("One!  Two? Three", ["One!", "Two?", "Three"]),
            ("Para one\nPara two.", ["Para one", "Para two."]),
            ("Version 2.1 shipped. Done.", ["Version 2.1 shipped.", "Done."]),
            ("   ", []),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SentenceSplitter.split(input), expected, input)
        }
    }

    func testPreviewKeepsTwentySentencesAndItsParagraphs() {
        let text = (1...12).map { "Sentence \($0)." }.joined(separator: " ") + "\n" + (13...25).map { "Sentence \($0)." }.joined(separator: " ")
        let preview = SentenceSplitter.preview(text, limit: 20)
        let lines = preview.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "paragraphs stay")
        XCTAssertTrue(lines[1].hasSuffix("Sentence 20. …"))
        XCTAssertEqual(SentenceSplitter.split(preview.replacingOccurrences(of: " …", with: "")).count, 20)

        XCTAssertEqual(SentenceSplitter.preview("One. Two.", limit: 20), "One. Two.", "nothing cut, no ellipsis")
        XCTAssertEqual(SentenceSplitter.preview("One. Two.\nThree.", limit: 2), "One. Two. …")
    }

    func testAppendOnlyStoreNumbersTextsAndSentences() {
        var store = EvidenceStore()
        let first = store.appendText("A. B.")
        let second = store.appendText("C.")
        XCTAssertEqual(first.text, 1)
        XCTAssertEqual(second.text, 2)
        XCTAssertEqual(store.sentence(text: 1, s: 2)?.sentence, "B.")
        XCTAssertEqual(store.sentence(text: 2, s: 1)?.sentence, "C.")
        XCTAssertEqual(store.count, 3)

        store.append(Sentence(text: 1, s: 2, sentence: "rewritten"))
        XCTAssertEqual(store.sentence(text: 1, s: 2)?.sentence, "B.", "an existing id is never rewritten")
    }

    func testJSONLRoundTrip() throws {
        var store = EvidenceStore()
        store.appendText("Hello there. General Kenobi.")
        store.append(Sentence(text: 2, s: 1, sentence: "spoken", t0: 1.5, t1: 3.25, speaker: "Speaker 1"))
        let jsonl = store.jsonl()
        XCTAssertEqual(jsonl.split(separator: "\n").count, 3)
        XCTAssertTrue(jsonl.contains(#"{"s":1,"sentence":"Hello there.","text":1}"#))
        XCTAssertEqual(try EvidenceStore(jsonl: jsonl), store)
    }

    func testProofNote() {
        let s = Sentence(text: 3, s: 12, sentence: "x")
        XCTAssertEqual(s.proofNote, "text 3 s12")
        XCTAssertEqual(SentenceID.parse(noteValue: "3 s12"), s.id)
        XCTAssertNil(SentenceID.parse(noteValue: "3 12"))
    }
}
