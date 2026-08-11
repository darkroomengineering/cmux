import MCP

/// `notification.*` tools: create/list/clear in-app notifications (the notification bell,
/// distinct from a macOS system notification). Handlers live in
/// `Sources/TerminalController+Notification.swift`.
enum NotificationTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "notification_create",
            socketMethod: "notification.create",
            description: "Creates a notification for a workspace, targeting an explicit surface or the workspace's focused surface.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "title": ProgramaToolSchema.string("Notification title. Defaults to \"Notification\"."),
                "subtitle": ProgramaToolSchema.string("Notification subtitle."),
                "body": ProgramaToolSchema.string("Notification body text."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to attach the notification to. If omitted, uses the resolved workspace's focused surface."),
            ])
        ),
        ProgramaTool(
            name: "notification_create_for_surface",
            socketMethod: "notification.create_for_surface",
            description: "Creates a notification for a specific surface within a workspace (surface_id is required, unlike notification_create).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to attach the notification to."),
                    "title": ProgramaToolSchema.string("Notification title. Defaults to \"Notification\"."),
                    "subtitle": ProgramaToolSchema.string("Notification subtitle."),
                    "body": ProgramaToolSchema.string("Notification body text."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "notification_create_for_target",
            socketMethod: "notification.create_for_target",
            description: "Creates a notification for an exact workspace + surface pair (both required), without any fallback resolution.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to attach the notification to."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to attach the notification to."),
                    "title": ProgramaToolSchema.string("Notification title. Defaults to \"Notification\"."),
                    "subtitle": ProgramaToolSchema.string("Notification subtitle."),
                    "body": ProgramaToolSchema.string("Notification body text."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id", "surface_id"]
            )
        ),
        ProgramaTool(
            name: "notification_list",
            socketMethod: "notification.list",
            description: "Lists every in-app notification currently in the notification bell, across all workspaces.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "notification_clear",
            socketMethod: "notification.clear",
            description: "Clears notifications. Scoped to one workspace if workspace_id is given, otherwise clears every notification globally.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to clear notifications for. Omit to clear all notifications."),
            ])
        ),
    ]
}
