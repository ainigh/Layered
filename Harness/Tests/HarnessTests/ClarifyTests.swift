import XCTest
@testable import Harness

final class ClarifyTests: XCTestCase {
    let transcript = Transcript(segments: [
        .init(t0: 0, t1: 4, text: "I'm writing a paper. Ana reviews it.", speaker: "Speaker 1"),
        .init(t0: 4, t1: 6, text: "The deadline is Nov 3.", speaker: "Speaker 2"),
    ])

    func testTranscriptBecomesTimedSentencesAndAContextParagraph() {
        var state = reduce(MapState(), .submitText("earlier text."), now: fixedDate)
        state = reduce(state, .submitTranscript(transcript), now: fixedDate)
        let sentences = state.evidence.sentences(text: 2)
        XCTAssertEqual(sentences.map(\.sentence), ["I'm writing a paper.", "Ana reviews it.", "The deadline is Nov 3."])
        XCTAssertEqual(sentences.map(\.speaker), ["Speaker 1", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(sentences[0].t0, 0)
        XCTAssertEqual(sentences[1].t1, 4)
        XCTAssertEqual(sentences[2].t0, 4)
        XCTAssertGreaterThan(sentences[1].t0!, 1.5, "the span is shared by length")
        XCTAssertEqual(state.context.paragraphs.last?.kind, .transcript)
        XCTAssertEqual(state.context.paragraphs.last?.textID, 2)
        XCTAssertEqual(state.context.paragraphs.last?.body, "[00:00] Speaker 1: I'm writing a paper. Ana reviews it.\n[00:04] Speaker 2: The deadline is Nov 3.")
        XCTAssertEqual(state.transcripts[2], transcript)
        XCTAssertTrue(state.log.isEmpty)
    }

    func testClarificationAnswersAppendToTheContextAndNameSpeakers() {
        var state = reduce(MapState(), .submitTranscript(transcript), now: fixedDate)
        state = reduce(state, .nameSpeaker(label: "Speaker 1", name: "Sam"), now: fixedDate)
        state = reduce(state, .answer(ClarifyQuestion(sentence: 3, reason: "time", question: "Which year?"), "2026"), now: fixedDate)
        state = reduce(state, .nameSpeaker(label: "nobody", name: "x"), now: fixedDate)
        state = reduce(state, .answer(nil, "   "), now: fixedDate)

        XCTAssertEqual(state.context.paragraphs.map(\.kind), [.transcript, .clarification, .clarification])
        XCTAssertEqual(state.context.paragraphs[1].body, "Speaker 1 is sam")
        XCTAssertEqual(state.context.paragraphs[2].body, "2026 (s3: Which year?)")
        XCTAssertEqual(state.speakers.names, ["speaker 1": "sam"])
        XCTAssertEqual(state.aliases, ["sam": ["speaker 1"]])
        XCTAssertEqual(state.evidence.nextTextID, 4, "each clarification is a text with its own evidence")
        XCTAssertEqual(state.context.plainText.contains("[clarification] Speaker 1 is sam"), true)
    }

    func testSpeakerAliasSupportsProof() {
        var state = reduce(MapState(), .submitTranscript(transcript), now: fixedDate)
        state = reduce(state, .nameSpeaker(label: "Speaker 1", name: "Sam"), now: fixedDate)
        state = reduce(state, .applyModelOutput("| sam - writes | paper @s 1\n| ana - reviews | paper @s 2", prompt: .extract, textID: 1, about: "text 1"), now: fixedDate)
        XCTAssertEqual(state.turns.last?.lines, [
            "| sam @src text @text 1 s1",
            "| paper @src text @text 1 s1",
            "| sam - writes @src text @text 1 s1 | paper",
            "| ana @src text @text 1 s2",
            "| ana - reviews @src text @text 1 s2 | paper",
        ])
    }

    func testSpeakerMapParsing() {
        XCTAssertEqual(SpeakerMap.parse("Speaker 2 is Dr. Ana.")?.0, "speaker 2")
        XCTAssertEqual(SpeakerMap.parse("Speaker 2 is Dr. Ana.")?.1, "dr. ana")
        XCTAssertNil(SpeakerMap.parse("Speaker one is Ana"))
        XCTAssertNil(SpeakerMap.parse("Ana is Speaker 1"))
        XCTAssertEqual(SpeakerMap(names: ["speaker 1": "ana", "speaker 3": "ana"]).aliases, ["ana": ["speaker 1", "speaker 3"]])
    }

    func testFixtureTranscriberAndPersistence() async throws {
        let fixture = FixtureTranscriber(transcript: transcript, labels: ["Speaker 1", "Speaker 2"])
        let t = try await fixture.transcribe(URL(fileURLWithPath: "/dev/null"), model: "large-v3-turbo") { _ in }
        XCTAssertEqual(t.model, "large-v3-turbo")
        let labelled = try await fixture.diarize(t, audio: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(labelled.speakers, ["Speaker 1", "Speaker 2"])

        let storage = InMemoryStorage()
        let state = reduce(reduce(MapState(), .submitTranscript(transcript), now: fixedDate), .nameSpeaker(label: "Speaker 2", name: "Ana"), now: fixedDate)
        Persistence.sync(before: MapState(), after: state, storage: storage)
        let loaded = try Persistence.load(storage)
        XCTAssertEqual(loaded.state.context, state.context)
        XCTAssertEqual(loaded.state.transcripts, state.transcripts)
        XCTAssertEqual(loaded.state.evidence, state.evidence)
        XCTAssertEqual(loaded.state.speakers, state.speakers)
    }
}
