extension ProgramaCLI {
    /// Subcommand help text for Hooks commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func hooksSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "claude-hook":
            return """
            Usage: programa claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | programa claude-hook session-start
              echo '{}' | programa claude-hook stop
            """
        case "codex":
            return """
            Usage: programa codex <install-hooks|uninstall-hooks>

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install programa hooks into ~/.codex/hooks.json,
                                 plus the agent skill into ~/.agents/skills/programa/
              uninstall-hooks   Remove programa hooks from ~/.codex/hooks.json,
                                 plus the agent skill if programa-managed
            """
        case "codex-hook":
            return """
            Usage: programa codex-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for Codex CLI integration. Reads JSON from stdin.
            Gracefully no-ops when not running inside programa.

            Subcommands:
              session-start   Register a Codex session
              prompt-submit   Set Running status on user prompt
              stop            Send completion notification, set Idle
              notification    Send an attention-classified notification, set Needs input
              session-end     Final cleanup when the Codex process exits (Ctrl+C/kill)

            Flags:
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        case "opencode":
            return """
            Usage: programa opencode <install-integration|uninstall-integration>

            Manage Programa's OpenCode plugin integration.

            Subcommands:
              install-integration     Install programa's plugin into ~/.config/opencode/plugins/programa.js,
                                       plus the agent skill into ~/.config/opencode/skills/programa/
              uninstall-integration   Remove programa's plugin (refuses if you've customized the file),
                                       plus the agent skill if programa-managed
            """
        case "opencode-hook":
            return """
            Usage: programa opencode-hook <session-start|prompt-submit|stop|notification|session-end> [flags]

            Hook for the OpenCode plugin integration. Reads --cwd/--session flags passed
            by the plugin (stdin JSON is tolerated but not required). Gracefully no-ops
            when not running inside programa.

            Subcommands:
              session-start   Register an OpenCode session (plugin boot)
              prompt-submit   Set Running status on user prompt (chat.message)
              stop            Send completion notification, set Idle (session.idle)
              notification    Send an attention notification, set Needs input (permission.asked)
              session-end     Final cleanup when the OpenCode plugin disposes

            Flags:
              --cwd <path>           Working directory reported by the plugin
              --session <id>         OpenCode session id, when available
              --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
            """
        default:
            return nil
        }
    }

    /// Hook command descriptors live beside their help text while hook-provider
    /// state and installation remain in CLI+Hooks.
    func hooksDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["claude-hook"],
                helpLines: ["claude-hook <session-start|stop|notification> [--workspace <id|ref>] [--surface <id|ref>]"],
                execute: { ctx in
                    try self.runClaudeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["codex-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runCodexHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
            CommandDescriptor(
                names: ["opencode-hook"],
                helpLines: [],
                execute: { ctx in
                    try self.runOpenCodeHook(commandArgs: ctx.commandArgs, client: ctx.client)
                }
            ),
        ]
    }
}
