import SwiftUI
import Harness

// Every view has a preview bound to a fixture, so design review happens without the model.

#Preview("Canvas · typical") {
    let model = AppModel()
    return MapWindow(session: MapSession.demo(.typical), model: model).frame(width: 1100, height: 720)
}

#Preview("Canvas · large") {
    let model = AppModel()
    return MapWindow(session: MapSession.demo(.large), model: model).frame(width: 1100, height: 720)
}

#Preview("Context panel") {
    PanelContainer(title: "Context", symbol: "doc.text", onClose: {}) {
        ContextPanel(session: Fixture.contextSession())
    }.frame(width: 340, height: 640)
}

#Preview("Details panel") {
    let s = MapSession.demo(.typical)
    s.selection = ["paper"]
    return PanelContainer(title: "Details", symbol: "info.circle", onClose: {}) {
        DetailsPanel(session: s)
    }.frame(width: 340, height: 640)
}

#Preview("Item overlay") {
    let s = Fixture.contextSession()
    return MapOverlay(session: s, overlay: .item(s.state.context.items.last!.id)).frame(width: 900, height: 640)
}

#Preview("Ask me overlay") {
    let s = MapSession.demo(.typical)
    s.clarifyQuestions = [ClarifyQuestion(sentence: 1, reason: "pronoun", question: "Who is \"they\"?")]
    return MapOverlay(session: s, overlay: .clarify).frame(width: 900, height: 640)
}

#Preview("Outline panel") {
    PanelContainer(title: "Outline", symbol: "list.bullet.indent", onClose: {}) {
        OutlinePanel(session: MapSession.demo(.typical))
    }.frame(width: 340)
}

#Preview("History panel") {
    PanelContainer(title: "History", symbol: "clock.arrow.circlepath", onClose: {}) {
        HistoryPanel(session: MapSession.demo(.typical))
    }.frame(width: 340)
}

#Preview("Settings panel") {
    PanelContainer(title: "Settings", symbol: "gearshape", onClose: {}) {
        SettingsPanel(session: MapSession.demo(.typical))
    }.frame(width: 420)
}

#Preview("Prompt panel") {
    PanelContainer(title: "Prompt", symbol: "text.quote", onClose: {}) {
        PromptPanel(session: MapSession.demo(.typical))
    }.frame(width: 420)
}

/// A demo session with one item of each kind: yours, a deselected one, a model reply.
@MainActor
enum Fixture {
    static func contextSession() -> MapSession {
        let s = MapSession.demo(.typical)
        s.addContext("Kim chairs the workshop in Lisbon.")
        s.addContext("The venue is still open.")
        s.dispatch(.selectContext(s.state.context.items.last!.id, false))
        s.dispatch(.addReply("Ana reviews the paper that Sam is writing; the deadline is Nov 3.", question: "who reviews?"))
        return s
    }
}
