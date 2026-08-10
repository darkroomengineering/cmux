import MCP

/// `workspace.*` tools other than the four focus-stealing ones (`workspace.select/next/
/// previous/last`, exposed as `focus_workspace_*` in `FocusTools.swift`). Handlers live in
/// `Sources/TerminalController+Workspace.swift` (CRUD/reorder/action) and
/// `Sources/TerminalController+Telemetry.swift` (status/log/progress/sidebar metadata).
enum WorkspaceTools {
    private static let workspaceActionValues = [
        "pin", "unpin", "rename", "clear_name",
        "set_description", "clear_description",
        "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below",
        "mark_read", "mark_unread",
        "set_color", "clear_color",
    ]

    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "workspace_list",
            socketMethod: "workspace.list",
            description: "Lists every workspace (sidebar tab) in a window, in display order, with pin/selection/remote status.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_create",
            socketMethod: "workspace.create",
            description: "Creates a new workspace (sidebar tab) with its own terminal, optionally with a starting directory, command, environment, title, and description.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "working_directory": ProgramaToolSchema.string("Starting directory for the new workspace's terminal. Takes priority over cwd if both are set."),
                "cwd": ProgramaToolSchema.string("Alias for working_directory, used only if working_directory is omitted."),
                "initial_command": ProgramaToolSchema.string("Shell command to run immediately in the new workspace's terminal."),
                "initial_env": ProgramaToolSchema.stringMap("Extra environment variables to set for the new workspace's terminal."),
                "title": ProgramaToolSchema.string("Custom title for the new workspace."),
                "description": ProgramaToolSchema.string("Custom description for the new workspace."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_current",
            socketMethod: "workspace.current",
            description: "Returns the currently selected workspace in a window, with its full summary.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_close",
            socketMethod: "workspace.close",
            description: "Closes a workspace (sidebar tab). Fails if the workspace is pinned.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref (e.g. workspace:2) to close."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_move_to_window",
            socketMethod: "workspace.move_to_window",
            description: "Moves a workspace from its current window into a different window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to move."),
                    "window_id": ProgramaToolSchema.string("Destination window UUID or short ref."),
                    "focus": ProgramaToolSchema.boolean("If true, bring the destination window forward and select the moved workspace after moving. Defaults to false."),
                ],
                required: ["workspace_id", "window_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_reorder",
            socketMethod: "workspace.reorder",
            description: "Reorders a workspace within its window's sidebar. Specify exactly one of index, before_workspace_id, or after_workspace_id.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to reorder."),
                    "index": ProgramaToolSchema.integer("Target zero-based index within the window's workspace list."),
                    "before_workspace_id": ProgramaToolSchema.string("Move this workspace to just before the workspace with this UUID/ref."),
                    "after_workspace_id": ProgramaToolSchema.string("Move this workspace to just after the workspace with this UUID/ref."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_rename",
            socketMethod: "workspace.rename",
            description: "Sets a workspace's custom display title.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to rename."),
                    "title": ProgramaToolSchema.string("New title for the workspace."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id", "title"]
            )
        ),
        ProgramaTool(
            name: "workspace_action",
            socketMethod: "workspace.action",
            description: "Runs one of a fixed set of workspace-level actions (pin, rename, reorder, close siblings, recolor, mark read/unread, etc). Some actions require extra params: rename needs title, set_description needs description, set_color needs color.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "action": ProgramaToolSchema.stringEnum("The workspace action to run.", workspaceActionValues),
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to act on. Defaults to the active window's selected workspace if omitted."),
                    "title": ProgramaToolSchema.string("New title, required when action is rename."),
                    "description": ProgramaToolSchema.string("New description, required when action is set_description."),
                    "color": ProgramaToolSchema.string("Hex color (#RRGGBB) or named color, required when action is set_color."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["action"]
            )
        ),
        ProgramaTool(
            name: "workspace_equalize_splits",
            socketMethod: "workspace.equalize_splits",
            description: "Proportionally equalizes pane split dividers in a workspace so leaf panes get equal space, optionally scoped to one split orientation.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "orientation": ProgramaToolSchema.stringEnum("Only equalize splits of this orientation. If omitted, equalizes every split.", ["horizontal", "vertical"]),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_set_status",
            socketMethod: "workspace.set_status",
            description: "Sets (or replaces) a single-line key/value status entry shown in a workspace's sidebar.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to set status on."),
                    "key": ProgramaToolSchema.string("Status entry key. Setting the same key again replaces the entry."),
                    "value": ProgramaToolSchema.string("Status entry value text."),
                    "icon": ProgramaToolSchema.string("Optional SF Symbol name to show next to the entry."),
                    "color": ProgramaToolSchema.string("Optional color for the entry."),
                    "format": ProgramaToolSchema.stringEnum("How to render the value. Defaults to plain.", ["plain", "markdown"]),
                    "priority": ProgramaToolSchema.integer("Sort priority, -9999 to 9999 (higher shows first). Defaults to 0."),
                    "url": ProgramaToolSchema.string("Optional http(s) URL the entry links to."),
                    "pid": ProgramaToolSchema.integer("Optional process id to associate with this status key, for stale-session detection."),
                ],
                required: ["workspace_id", "key", "value"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_status",
            socketMethod: "workspace.clear_status",
            description: "Removes a single sidebar status entry by key.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Status entry key to remove."),
                ],
                required: ["workspace_id", "key"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_status",
            socketMethod: "workspace.list_status",
            description: "Lists all sidebar status entries for a workspace, in display order.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_log",
            socketMethod: "workspace.log",
            description: "Appends one entry to a workspace's sidebar activity log.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "message": ProgramaToolSchema.string("Log message text."),
                    "level": ProgramaToolSchema.stringEnum("Log severity. Defaults to info.", ["info", "progress", "success", "warning", "error"]),
                    "source": ProgramaToolSchema.string("Optional short label for what produced this log entry."),
                ],
                required: ["workspace_id", "message"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_log",
            socketMethod: "workspace.clear_log",
            description: "Clears a workspace's entire sidebar activity log.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_log",
            socketMethod: "workspace.list_log",
            description: "Lists a workspace's sidebar activity log entries, optionally limited to the most recent N.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "limit": ProgramaToolSchema.integer("Maximum number of most-recent entries to return. Omit for all entries."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_set_progress",
            socketMethod: "workspace.set_progress",
            description: "Sets a workspace's sidebar progress indicator.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "value": ProgramaToolSchema.number("Progress value, clamped to 0.0-1.0."),
                    "label": ProgramaToolSchema.string("Optional label shown alongside the progress bar."),
                ],
                required: ["workspace_id", "value"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_progress",
            socketMethod: "workspace.clear_progress",
            description: "Clears a workspace's sidebar progress indicator.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_sidebar_state",
            socketMethod: "workspace.sidebar_state",
            description: "Returns a workspace's full sidebar state in one call: color, cwd, git branch, pull request, progress, status entries, metadata blocks, and recent log entries.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_clear_agent_pid",
            socketMethod: "workspace.clear_agent_pid",
            description: "Removes a tracked agent process id from a workspace (used for stale-session detection).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Agent PID entry key to remove."),
                ],
                required: ["workspace_id", "key"]
            )
        ),
        ProgramaTool(
            name: "workspace_set_agent_pid",
            socketMethod: "workspace.set_agent_pid",
            description: "Registers an agent process id under a key for a workspace (used for stale-session detection and OSC suppression); does not set a visible status entry.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Key to register this PID under."),
                    "pid": ProgramaToolSchema.integer("Process id, must be a positive integer."),
                ],
                required: ["workspace_id", "key", "pid"]
            )
        ),
        ProgramaTool(
            name: "workspace_report_meta_block",
            socketMethod: "workspace.report_meta_block",
            description: "Sets (or replaces) a freeform markdown metadata block in a workspace's sidebar, distinct from the single-line status entries set by workspace_set_status.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Metadata block key. Setting the same key again replaces the block."),
                    "markdown": ProgramaToolSchema.string("Markdown content for the block."),
                    "priority": ProgramaToolSchema.integer("Sort priority, -9999 to 9999 (higher shows first). Defaults to 0."),
                ],
                required: ["workspace_id", "key", "markdown"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_meta_block",
            socketMethod: "workspace.clear_meta_block",
            description: "Removes a sidebar metadata block by key.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Metadata block key to remove."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_meta_blocks",
            socketMethod: "workspace.list_meta_blocks",
            description: "Lists all sidebar metadata blocks for a workspace, in display order.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_reset_sidebar",
            socketMethod: "workspace.reset_sidebar",
            description: "Clears all sidebar context for a workspace: status entries, log, progress, metadata blocks, and agent state.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
    ]
}
