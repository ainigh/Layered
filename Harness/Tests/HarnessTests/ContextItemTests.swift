import XCTest
@testable import Harness

/// The Context panel's list: items added, edited, selected, deleted and put on the map,
/// each an appended record in `context.md`.
final class ContextItemTests: XCTestCase {
    let transcript = Transcript(segments: [
        .init(t0: 0, t1: 4, text: "I'm writing a paper. Ana reviews it.", speaker: "Speaker 1"),
    ])

    /// A state with a typed item (1), a transcript (2) and a model reply (3).
    func three() -> MapState {
        var state = reduce(MapState(), .submitText("Sam writes the paper.", kind: .typed), now: fixedDate)
        state = reduce(state, .submitTranscript(transcript), now: fixedDate)
        state = reduce(state, .addReply("The deadline is Nov 3.", question: "when is it due?"), now: fixedDate)
        return state
    }

    func testEachAddIsAnItemAndModelRepliesWaitToBeSelected() {
        let items = three().context.items
        XCTAssertEqual(items.map(\.id), [1, 2, 3])
        XCTAssertEqual(items.map(\.origin), [.you, .audio, .model])
        XCTAssertEqual(items.map(\.selected), [true, true, false])
        XCTAssertEqual(items.map(\.textID), [1, 2, 3])
        XCTAssertEqual(items.map(\.isPending), [true, true, false], "a model reply is never extracted")
        XCTAssertEqual(items.map(\.isEditable), [true, false, true], "text from audio stays as transcribed")
        XCTAssertEqual(items[2].question, "when is it due?")
        XCTAssertEqual(three().log, [], "adding context never touches the map")
    }

    func testActionsAppendRecordsAndNeverRewrite() {
        // (action, what the item looks like after, records appended)
        typealias Check = (ContextItem) -> Bool
        let cases: [(String, Action, Int, Check, Int)] = [
            ("deselect", .selectContext(1, false), 1, { !$0.selected }, 1),
            ("select again is a no-op", .selectContext(1, true), 1, { $0.selected }, 0),
            ("select a reply", .selectContext(3, true), 3, { $0.selected }, 1),
            ("delete", .removeContext(1), 1, { $0.removed && !$0.isPending }, 1),
            ("restore what is not deleted", .restoreContext(1), 1, { !$0.removed }, 0),
            ("edit", .reviseContext(1, "Sam writes the thesis."), 1, { $0.body == "Sam writes the thesis." && $0.revisions.count == 2 && $0.textID == 4 }, 1),
            ("edit to the same text", .reviseContext(1, "Sam writes the paper."), 1, { $0.revisions.count == 1 }, 0),
            ("edit a transcript", .reviseContext(2, "something else"), 2, { $0.revisions.count == 1 }, 0),
            ("edit a reply makes it yours and selects it", .reviseContext(3, "Due Nov 3, 2026."), 3, { $0.origin == .you && $0.selected && $0.question == "when is it due?" }, 2),
            ("on the map", .markExtracted(textID: 2), 2, { $0.isOnMap && !$0.isPending }, 1),
            ("unknown item", .removeContext(9), 1, { !$0.removed }, 0),
        ]
        for (name, action, id, check, appended) in cases {
            let before = three()
            let after = reduce(before, action, now: fixedDate)
            XCTAssertEqual(after.context.paragraphs.count - before.context.paragraphs.count, appended, name)
            XCTAssertEqual(Array(after.context.paragraphs.prefix(before.context.paragraphs.count)), before.context.paragraphs, "\(name): earlier records untouched")
            XCTAssertTrue(check(after.context.item(id)!), name)
        }
    }

    func testRemoveThenRestore() {
        var state = reduce(three(), .removeContext(2), now: fixedDate)
        XCTAssertEqual(state.context.selectedTexts, [1])
        state = reduce(state, .restoreContext(2), now: fixedDate)
        XCTAssertEqual(state.context.selectedTexts, [1, 2])
    }

    func testSubmitSendsWhatChangedSinceTheMap() {
        var state = reduce(MapState(), .submitText("Para one.\n\nPara two.", kind: .typed), now: fixedDate)
        XCTAssertEqual(Submit.request(for: state.context.item(1)!), "Para one.\n\nPara two.")
        state = reduce(state, .markExtracted(textID: 1), now: fixedDate)
        XCTAssertEqual(state.context.pendingItems.map(\.id), [])
        state = reduce(state, .reviseContext(1, "Para one.\n\nPara two, changed.\n\nPara three."), now: fixedDate)
        XCTAssertEqual(state.context.pendingItems.map(\.id), [1], "an edit puts the item back in line")
        XCTAssertEqual(Submit.request(for: state.context.item(1)!), "Para two, changed.\n\nPara three.")
        state = reduce(state, .reviseContext(1, "Para one."), now: fixedDate)
        XCTAssertEqual(Submit.request(for: state.context.item(1)!), "", "an edit that only removes text has nothing to extract")
        XCTAssertFalse(state.context.pendingItems.isEmpty)
        // A deselected item waits.
        state = reduce(state, .selectContext(1, false), now: fixedDate)
        XCTAssertEqual(state.context.pendingItems.map(\.id), [])
    }

    func testRoundTripThroughMarkdown() {
        var state = three()
        state = reduce(state, .selectContext(1, false), now: fixedDate)
        state = reduce(state, .reviseContext(3, "Due Nov 3.\n[note]\nreally."), now: fixedDate)
        state = reduce(state, .removeContext(2), now: fixedDate)
        state = reduce(state, .markExtracted(textID: 1), now: fixedDate)
        let md = state.context.markdown
        XCTAssertTrue(md.contains("[item 3 · text 3 · model · re: when is it due? · 2026-10-28T14:02:33Z]\nThe deadline is Nov 3.\n\n"))
        XCTAssertTrue(md.contains("[item 1 · typed · deselected · 2026-10-28T14:02:33Z]\n\n"))
        XCTAssertTrue(md.contains("\n [note]\n"), "a body line that reads as a header is indented")
        let read = ContextDocument(markdown: md)
        XCTAssertEqual(read, state.context)
        XCTAssertEqual(read.items, state.context.items)
        XCTAssertEqual(read.item(3)?.body, "Due Nov 3.\n[note]\nreally.")
    }

    func testRecordsFromBeforeItemsAreItemsOnTheMap() {
        let md = "[text 1 · pasted · 2026-10-28T14:02:33Z]\nI'm Sam.\n\n[clarification · 2026-10-28T14:02:33Z]\nSpeaker 1 is Ana\n\n"
        var doc = ContextDocument(markdown: md)
        XCTAssertEqual(doc.items.map(\.id), [1, 2])
        XCTAssertEqual(doc.items.map(\.isOnMap), [true, false])
        XCTAssertEqual(doc.nextItemID, 3)
        doc.append(ContextParagraph(kind: .pasted, item: 1, event: .deselected, date: fixedDate, body: ""))
        XCTAssertEqual(doc.items.first?.selected, false, "an event can name an item numbered by position")
    }

    func testTheModelReadsTheSelectionAndRepliesAreNeverProof() async throws {
        var state = three()
        state = reduce(state, .selectContext(3, true), now: fixedDate)
        state = reduce(state, .selectContext(1, false), now: fixedDate)
        XCTAssertEqual(state.modelTexts, [2, 3])
        XCTAssertEqual(state.proofEvidence.sentences.map(\.text), [1, 2, 2], "the reply's sentence is not evidence")

        let runner = ModelRunner(client: FixtureClient(recordings: []), settings: ModelSettings(model: "fixture"))
        let prompt = runner.prompt(.clarify, state: state, item: "")
        XCTAssertFalse(prompt.contains("Sam writes the paper."), "a deselected item is left out")
        XCTAssertTrue(prompt.contains("[text 2]\ns1 (Speaker 1): I'm writing a paper."))
        XCTAssertTrue(prompt.contains("[text 3 · your earlier reply, not evidence]\ns1: The deadline is Nov 3."))
        XCTAssertTrue(runner.prompt(.clarify, state: state, item: "", texts: [1]).contains("Sam writes the paper."), "a request about one item reads that item")

        // A `text` line that only a reply supports is downgraded.
        let next = reduce(state, .applyModelOutput("| deadline @src text", prompt: .expand, textID: nil, about: "x"), now: fixedDate)
        XCTAssertEqual(next.graph.node("deadline")?.note(kind: "src"), "guess")
    }

    func testCoverageCountsOnlyTheCurrentContext() {
        var state = three()
        XCTAssertEqual(Set(Coverage.compute(state).uncoveredSentences.map(\.text)), [1, 2], "replies are not facts to cover")
        state = reduce(state, .selectContext(2, false), now: fixedDate)
        XCTAssertEqual(Set(Coverage.compute(state).uncoveredSentences.map(\.text)), [1])
    }

    func testDeletingASpeakerAnswerForgetsTheName() {
        var state = reduce(three(), .nameSpeaker(label: "Speaker 1", name: "Sam"), now: fixedDate)
        XCTAssertEqual(state.speakers.names, ["speaker 1": "sam"])
        state = reduce(state, .removeContext(4), now: fixedDate)
        XCTAssertEqual(state.speakers.names, [:])
    }

    func testSentenceWalkAcrossTexts() {
        var walk = SentenceWalk(sentences: [Sentence(text: 1, s: 1, sentence: "A."), Sentence(text: 1, s: 2, sentence: "B."), Sentence(text: 4, s: 1, sentence: "C.")])
        XCTAssertEqual(walk.textID, 1)
        XCTAssertNil(walk.advance())
        XCTAssertEqual(walk.advance(), 1, "text 1 is done")
        XCTAssertEqual(walk.advance(), 4)
        XCTAssertTrue(walk.isFinished)
        XCTAssertNil(walk.advance())
    }

    func testEventsReachTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layered-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = try FolderStorage(root: root)
        let first = three()
        Persistence.sync(before: MapState(), after: first, storage: storage)
        var next = reduce(first, .removeContext(1), now: fixedDate)
        next = reduce(next, .reviseContext(3, "Mine now."), now: fixedDate)
        Persistence.sync(before: first, after: next, storage: storage)
        let loaded = try Persistence.load(storage)
        XCTAssertEqual(loaded.state.context.items, next.context.items)
        XCTAssertEqual(loaded.state.evidence, next.evidence)
    }
}
