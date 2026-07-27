import AppKit
import Foundation

@MainActor
struct ProgramaConfigExecutor {

    static func execute(
        command: ProgramaCommandDefinition,
        tabManager: TabManager,
        baseCwd: String,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        guard confirmIfUntrusted(
            command: command,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else { return }

        if let workspace = command.workspace {
            executeWorkspaceCommand(command: command, workspace: workspace, tabManager: tabManager, baseCwd: baseCwd)
        } else if let rawCommand = command.command {
            guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
            terminal.sendInput(sanitizeForDisplay(rawCommand) + "\n")
        }
    }

    /// The security decision, isolated from the UI so it can be tested directly.
    ///
    /// | directory | `confirm:` | prompt? |
    /// |-----------|------------|---------|
    /// | untrusted | absent     | **yes** -- this is the case that used to run silently |
    /// | untrusted | true       | yes     |
    /// | trusted   | absent     | no      |
    /// | trusted   | true       | yes -- author's "ask me anyway" marker |
    static func requiresConfirmation(confirmFlag: Bool, isTrusted: Bool) -> Bool {
        if !isTrusted { return true }
        return confirmFlag
    }

    /// The single gate in front of everything a `programa.json` can run. Returns false when the
    /// user declined, in which case the caller must not execute.
    ///
    /// Trust is the app's decision, not the config file's. It previously was not: the gate ran
    /// only `if command.confirm == true`, and `confirm` is a field in the very file we are
    /// deciding whether to trust, so any config could opt out of being checked by simply
    /// omitting it. `workspace`-type commands were never gated at all, despite being able to
    /// carry an arbitrary `command` and `env` per surface. Between them, cloning a repo and
    /// picking a plausible-looking entry out of the command palette ran arbitrary shell with no
    /// prompt.
    ///
    /// Now:
    ///  - untrusted directory: always confirm, whatever the file says, for every command type;
    ///  - trusted directory: run, unless the author set `confirm: true`, which stays meaningful
    ///    as a "this one is destructive, ask me anyway" marker;
    ///  - no source path: the global config at `~/.config/programa/`, which the user wrote
    ///    themselves. `ProgramaDirectoryTrust.isTrusted` already treats it as trusted, and
    ///    `ProgramaConfigSourceTrackingTests` pins the invariant that local commands always
    ///    carry a source path, so nil really does mean global.
    private static func confirmIfUntrusted(
        command: ProgramaCommandDefinition,
        configSourcePath: String?,
        globalConfigPath: String
    ) -> Bool {
        // No source path means the global config in ~/.config/programa, written by the user.
        let trusted = configSourcePath.map {
            ProgramaDirectoryTrust.shared.isTrusted(configPath: $0, globalConfigPath: globalConfigPath)
        } ?? true

        guard requiresConfirmation(confirmFlag: command.confirm == true, isTrusted: trusted) else {
            return true
        }

        return showConfirmDialog(
            command: describeForConfirmation(command),
            configPath: trusted ? nil : configSourcePath
        )
    }

    /// Human-readable summary of everything a command would run, for the confirmation dialog.
    /// A `workspace` command can spawn several surfaces each with its own shell command, so
    /// showing only the workspace name would hide exactly the part worth reviewing.
    /// Internal rather than private so `ProgramaConfigConsentDisclosureTests` can assert the
    /// exact text the user is shown. What this returns *is* the security boundary: the gate
    /// only obtains meaningful consent if this discloses everything the entry would do.
    static func describeForConfirmation(_ command: ProgramaCommandDefinition) -> String {
        if let rawCommand = command.command {
            return sanitizeForDisplay(rawCommand)
        }

        guard let workspace = command.workspace else {
            return sanitizeForDisplay(command.name)
        }

        let workspaceName = workspace.name ?? command.name
        var lines = [String(
            format: String(
                localized: "dialog.cmuxConfig.confirmCommand.workspaceSummary",
                defaultValue: "Open workspace \"%@\""
            ),
            sanitizeForDisplay(workspaceName)
        )]

        let surfaceLines = workspace.layout.map(surfaceDescriptions(in:)) ?? []
        if surfaceLines.isEmpty {
            return lines[0]
        }
        lines.append("")
        lines.append(contentsOf: surfaceLines.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    /// Every observable thing a layout's surfaces would do, depth-first in layout order.
    ///
    /// A surface with no `command` can still run code: `env` reaches the process
    /// unfiltered (only Programa's own `PROGRAMA_*` identity keys are protected, see
    /// `protectedStartupEnvironmentKeys` in TerminalSurface.swift), so `ZDOTDIR` /
    /// `BASH_ENV` / `ENV` set here execute a repo-controlled shell startup file the
    /// moment the surface spawns. Filtering surfaces down to "has a command" -- as this
    /// function used to -- let such a surface contribute nothing to the dialog, so the
    /// user would approve a workspace the dialog claimed ran nothing. Every surface that
    /// sets `command`, `cwd`, or `env` must produce a visible line.
    private static func surfaceDescriptions(in node: ProgramaLayoutNode) -> [String] {
        switch node {
        case let .pane(pane):
            return pane.surfaces.compactMap(describeSurface)
        case let .split(split):
            return split.children.flatMap(surfaceDescriptions(in:))
        }
    }

    /// Human-readable summary of one surface's observable effects, or nil if it does
    /// nothing (no command, cwd, or env). Every attacker-controlled string is sanitized
    /// individually before composition.
    private static func describeSurface(_ surface: ProgramaSurfaceDefinition) -> String? {
        var parts: [String] = []

        if let command = surface.command, !command.isEmpty {
            parts.append(sanitizeForDisplay(command))
        }
        if let cwd = surface.cwd, !cwd.isEmpty {
            parts.append("cwd=" + sanitizeForDisplay(cwd))
        }
        if let env = surface.env, !env.isEmpty {
            let pairs = env.keys.sorted().map { key in
                "\(sanitizeForDisplay(key))=\(sanitizeForDisplay(env[key] ?? ""))"
            }
            parts.append("env: " + pairs.joined(separator: " "))
        }

        guard !parts.isEmpty else { return nil }

        if let name = surface.name, !name.isEmpty {
            return "\(sanitizeForDisplay(name)): \(parts.joined(separator: "  "))"
        }
        return parts.joined(separator: "  ")
    }

    /// Show a confirmation dialog with the command text and, when `configPath` is non-nil, a
    /// "trust this directory" checkbox. Returns true if the user chose to run.
    ///
    /// `configPath` is nil when the directory is already trusted and we are only here because
    /// the author marked this entry `confirm: true`. Offering "always trust this folder" there
    /// would be misleading -- the folder is already trusted, and ticking it would not stop the
    /// prompt, because a `confirm: true` entry is meant to ask every time.
    private static func showConfirmDialog(command: String, configPath: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.cmuxConfig.confirmCommand.title",
            defaultValue: "Run Command"
        )
        let messageFormat = String(
            localized: "dialog.cmuxConfig.confirmCommand.messageWithCommand",
            defaultValue: "This will run the following command:\n\n%@"
        )
        // `command` is already the fully composed, per-component-sanitized summary from
        // `describeForConfirmation` -- re-running sanitizeForDisplay on the whole string here
        // would collapse the real newlines between entries that the caller relies on to keep
        // each surface on its own line.
        alert.informativeText = String(format: messageFormat, command)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.run",
            defaultValue: "Run"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.cancel",
            defaultValue: "Cancel"
        ))

        var checkbox: NSButton?
        if configPath != nil {
            let box = NSButton(checkboxWithTitle: String(
                localized: "dialog.cmuxConfig.confirmCommand.trustDirectory",
                defaultValue: "Always trust commands from this folder"
            ), target: nil, action: nil)
            box.state = .off
            alert.accessoryView = box
            checkbox = box
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        if let configPath, checkbox?.state == .on {
            ProgramaDirectoryTrust.shared.trust(configPath: configPath)
        }

        return true
    }

    /// Max characters kept from a single attacker-controlled value before truncating. Bounds
    /// how much text one value can contribute to the dialog, so a crafted string can't push
    /// the rest of the summary out of `NSAlert.informativeText`'s non-scrolling area or pad
    /// itself with fake trailing "system" text. This only bounds a single value -- callers
    /// still join multiple sanitized values with real newlines to build the full summary.
    private static let maxDisplayValueLength = 200

    private static func sanitizeForDisplay(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        // Collapse newlines WITHIN this single value -- the composed multi-line summary
        // still needs real newlines BETWEEN entries, which callers add after this returns.
        let collapsed = filtered.replacingOccurrences(
            of: "[\\r\\n]+",
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count > maxDisplayValueLength else { return trimmed }
        let truncationMarker = String(
            localized: "dialog.cmuxConfig.confirmCommand.truncated",
            defaultValue: "… (truncated)"
        )
        return trimmed.prefix(maxDisplayValueLength) + truncationMarker
    }

    private static func executeWorkspaceCommand(
        command: ProgramaCommandDefinition,
        workspace wsDef: ProgramaWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String
    ) {
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .ignore

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .ignore:
                tabManager.selectWorkspace(existing)
                return
            case .recreate:
                tabManager.closeWorkspace(existing)
            case .confirm:
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.title",
                    defaultValue: "Workspace Already Exists"
                )
                alert.informativeText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.message",
                    defaultValue: "A workspace with this name already exists. Close it and create a new one?"
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.recreate", defaultValue: "Recreate"))
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.cancel", defaultValue: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    tabManager.selectWorkspace(existing)
                    return
                }
                tabManager.closeWorkspace(existing)
            }
        }

        let resolvedCwd = ProgramaConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(workingDirectory: resolvedCwd)
        newWorkspace.setCustomTitle(workspaceName)
        if let color = wsDef.color {
            newWorkspace.setCustomColor(color)
        }

        guard let layout = wsDef.layout else { return }
        newWorkspace.applyCustomLayout(layout, baseCwd: resolvedCwd)
    }
}
