import SwiftUI

/// The "worst-of" badge for a workspace or a single surface. Ordering
/// (`blocked` > `working` > `idle`) is the whole point of the glance screen:
/// blocked workspaces sort to the top.
enum AgentBadge: Int, Comparable, Sendable {
    case idle = 0
    case working = 1
    case blocked = 2

    static func < (lhs: AgentBadge, rhs: AgentBadge) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var symbolName: String {
        switch self {
        case .blocked: "exclamationmark.octagon.fill"
        case .working: "bolt.fill"
        case .idle: "moon.zzz.fill"
        }
    }

    var label: String {
        switch self {
        case .blocked: "Blocked"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    /// Semantic colors (not literals) so this reads correctly in Dark Mode.
    var tint: Color {
        switch self {
        case .blocked: .red
        case .working: .blue
        case .idle: .secondary
        }
    }
}

struct WorkspaceRow: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var selected: Bool
    var index: Int
}

struct SurfaceRow: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var focused: Bool
    var agentState: AgentState?
    var agentStateSource: AgentStateSource?

    var badge: AgentBadge {
        switch agentState {
        case .blocked: .blocked
        case .working: .working
        case .idle, .none: .idle
        }
    }
}
