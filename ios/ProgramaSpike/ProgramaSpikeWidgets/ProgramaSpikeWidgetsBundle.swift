// `Widget` and `WidgetBundle` are declared in SwiftUI, not WidgetKit --
// importing only WidgetKit compiles the import fine and then fails with
// "cannot find type 'WidgetBundle' in scope", which reads like a missing
// framework rather than a missing import.
import SwiftUI
import WidgetKit

@main
struct ProgramaSpikeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}
