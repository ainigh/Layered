import SwiftUI
import Harness

// Harness and SwiftUI both declare these names. A declaration in this module wins over both
// imports, so each one is settled here once instead of qualified at every use.
typealias Text = SwiftUI.Text
typealias Path = SwiftUI.Path
typealias Layout = Harness.Layout
typealias Settings = Harness.Settings
typealias Transition = Harness.Transition
typealias Edge = Harness.Edge
