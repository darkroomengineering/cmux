import Foundation

/// Owns helper JSON-RPC routing so TerminalController's protocol adapter stays focused on
/// request framing, policy, and response encoding.
enum AgentRPCDispatcher {
    static func dispatch(
        method: String,
        params: [String: Any],
        controller: TerminalController
    ) -> TerminalController.V2CallResult? {
        switch method {
        case "agent.task.start":
            return controller.v2AgentTaskStart(params: params)
        case "agent.task.update":
            return controller.v2AgentTaskUpdate(params: params)
        case "agent.task.finish":
            return controller.v2AgentTaskFinish(params: params)
        case "agent.task.finish_session":
            return controller.v2AgentTaskFinishSession(params: params)
        case "agent.task.list":
            return controller.v2AgentTaskList(params: params)
        case "agent.spawn":
            return controller.v2AgentSpawn(params: params)
        default:
            return nil
        }
    }
}
