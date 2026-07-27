import ActivityKit

/// Shared between the app target (`ProgramaSpike`) and the widget extension
/// target (`ProgramaSpikeWidgets`) -- this file is listed in both targets'
/// `sources` in `project.yml`. `ContentState` is serialized on every
/// `Activity.update`, so keep it small.
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var blockedCount: Int
        var workingCount: Int
        /// Title of the workspace that most recently became blocked, if any.
        var headlineWorkspace: String?
    }

    /// Set once when the activity starts; the Mac this phone is paired to.
    var macName: String
}
