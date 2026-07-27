import Foundation

// MARK: - Agent state

/// Exactly the three values the wire contract permits. `agent_state`/
/// `agent_state_source` field names and values confirmed against
/// `Sources/TerminalController+Surface.swift` (`v2SurfaceList`) and
/// `tests_v2/test_agent_activity_state_socket.py`.
enum AgentState: String, Codable, Sendable {
    case working
    case blocked
    case idle
}

enum AgentStateSource: String, Codable, Sendable {
    case hooks
    case inferred
}

// MARK: - Request params

/// A minimal `Sendable`/`Codable` JSON value covering only the param shapes
/// our allowed methods actually need (plain strings for `workspace_id`/
/// `surface_id`/`text`, a string array for `subscribe`'s `classes`).
/// Deliberately not a fully general `JSONValue` -- the wire contract only
/// calls for these two shapes from the client side.
enum RPCParam: Sendable, Encodable {
    case string(String)
    case stringArray([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .stringArray(values):
            try container.encode(values)
        }
    }
}

// MARK: - Errors

struct WireErrorPayload: Decodable, Sendable {
    let code: String
    let message: String?
}

enum BridgeError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case invalidTicket
    case disconnected
    case encodingFailed
    case malformedResponse
    case rpc(code: String, message: String?)

    var description: String {
        switch self {
        case .notConnected: "not connected to the bridge"
        case .invalidTicket: "could not parse the pairing ticket"
        case .disconnected: "connection closed"
        case .encodingFailed: "failed to encode request"
        case .malformedResponse: "malformed response from bridge"
        case let .rpc(code, message): message.map { "\(code): \($0)" } ?? code
        }
    }
}

// MARK: - workspace.list
// Field names confirmed against Sources/TerminalController+Workspace.swift
// (v2WorkspaceList / v2WorkspaceSummaryPayload) and tests_v2/cmux.py's
// list_workspaces() helper.

struct WireWorkspace: Decodable, Sendable {
    let id: String
    let title: String?
    let selected: Bool?
    let index: Int?
}

struct WireWorkspaceListResult: Decodable, Sendable {
    let workspaces: [WireWorkspace]?
}

// MARK: - surface.list
// Field names confirmed against Sources/TerminalController+Surface.swift
// (v2SurfaceList) and tests_v2/test_agent_activity_state_socket.py /
// tests_v2/test_surface_list_custom_titles.py. Note: the real `surface.list`
// response carries `workspace_id` once at the top level (the call is scoped
// to one workspace), not per-surface as the wire-contract prose suggested --
// the client attaches workspace_id itself from the request context instead
// of reading it off each surface row.

struct WireSurface: Decodable, Sendable {
    let id: String
    let title: String?
    let focused: Bool?
    let agentState: AgentState?
    let agentStateSource: AgentStateSource?

    enum CodingKeys: String, CodingKey {
        case id, title, focused
        case agentState = "agent_state"
        case agentStateSource = "agent_state_source"
    }
}

struct WireSurfaceListResult: Decodable, Sendable {
    let workspaceId: String?
    let surfaces: [WireSurface]?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case surfaces
    }
}

// MARK: - subscribe
// Response shape per docs/v2-api-migration.md "Socket Event Subscriptions".

struct WireSubscribeResult: Decodable, Sendable {
    let subscriptionId: String?
    let classes: [String]?

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case classes
    }
}

// MARK: - agent.prompt
// Response shape per docs/v2-api-migration.md "agent.prompt (#166)".

struct WireAgentPromptResult: Decodable, Sendable {
    let workspaceId: String?
    let surfaceId: String?
    let workingObserved: Bool?
    let finalState: String?
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case workingObserved = "working_observed"
        case finalState = "final_state"
        case warning
    }
}

// MARK: - Event frames
// Shapes per docs/v2-api-migration.md "Event frames" / the task's wire
// contract. Event frames have an "event" key and no "id".

struct WireAgentStateEvent: Decodable, Sendable {
    let workspaceId: String
    let surfaceId: String
    let state: AgentState?
    let source: AgentStateSource?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case state, source
    }
}

struct WireOutputEvent: Decodable, Sendable {
    let workspaceId: String
    let surfaceId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case text
    }
}

struct WireWorkspaceLifecycleEvent: Decodable, Sendable {
    let kind: String
    let workspaceId: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case workspaceId = "workspace_id"
        case title
    }
}

struct WireDroppedEvent: Decodable, Sendable {
    let count: Int
}

enum BridgeEvent: Sendable {
    case agentState(WireAgentStateEvent)
    case output(WireOutputEvent)
    case workspaceLifecycle(WireWorkspaceLifecycleEvent)
    case dropped(Int)
}
