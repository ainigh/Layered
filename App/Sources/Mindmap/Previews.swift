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
    PanelContainer(title: "Context", symbol: "doc.text", placement: .constant(PanelPlacement()), onClose: {}) {
        ContextPanel(session: MapSession.demo(.tiny))
    }.frame(width: 340)
}

#Preview("Proof panel") {
    let s = MapSession.demo(.typical)
    s.selection = ["paper"]
    return PanelContainer(title: "Proof", symbol: "checkmark.seal", placement: .constant(PanelPlacement()), onClose: {}) {
        ProofPanel(session: s)
    }.frame(width: 340)
}

#Preview("Outline panel") {
    PanelContainer(title: "Outline", symbol: "list.bullet.indent", placement: .constant(PanelPlacement()), onClose: {}) {
        OutlinePanel(session: MapSession.demo(.typical))
    }.frame(width: 340)
}

#Preview("History panel") {
    PanelContainer(title: "History", symbol: "clock.arrow.circlepath", placement: .constant(PanelPlacement()), onClose: {}) {
        HistoryPanel(session: MapSession.demo(.typical))
    }.frame(width: 340)
}

#Preview("Settings panel") {
    PanelContainer(title: "Settings", symbol: "gearshape", placement: .constant(PanelPlacement()), onClose: {}) {
        SettingsPanel(session: MapSession.demo(.typical))
    }.frame(width: 420)
}

#Preview("Prompt panel") {
    PanelContainer(title: "Prompt", symbol: "text.quote", placement: .constant(PanelPlacement()), onClose: {}) {
        PromptPanel(session: MapSession.demo(.typical))
    }.frame(width: 420)
}
