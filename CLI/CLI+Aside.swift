import Foundation

/// Locates the Aside CLI (https://docs.aside.com) on disk. Pure and process-free so
/// it can be unit tested without touching the real filesystem.
struct AsideCLILocator {
    static func resolve(environment: [String: String], fileExists: (String) -> Bool) -> String? {
        if let home = environment["HOME"], !home.isEmpty {
            let localBin = (home as NSString).appendingPathComponent(".local/bin/aside")
            if fileExists(localBin) {
                return localBin
            }
            let cliApp = (home as NSString).appendingPathComponent(".aside/cli/Aside CLI.app/Contents/MacOS/aside")
            if fileExists(cliApp) {
                return cliApp
            }
        }
        let entries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = (entry as NSString).appendingPathComponent("aside")
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Builds the command plan for registering/removing Aside's MCP server(s) with
/// Claude Code and Codex. Pure so the exact argv can be unit tested without
/// spawning a process.
struct AsideMCPPlan {
    let claudeCommands: [[String]]
    let codexCommands: [[String]]

    static func build(
        asidePath: String,
        claudeExecutable: String?,
        codexExecutable: String?,
        withDevTools: Bool,
        install: Bool
    ) -> AsideMCPPlan {
        var claudeCommands: [[String]] = []
        var codexCommands: [[String]] = []

        if let claude = claudeExecutable {
            if install {
                claudeCommands.append([
                    claude, "mcp", "add", "--scope", "user", "--transport", "stdio", "aside", "--", asidePath, "mcp",
                ])
                if withDevTools {
                    claudeCommands.append([
                        claude, "mcp", "add", "--scope", "user", "--transport", "stdio", "aside-devtools",
                        "--", "npx", "-y", "chrome-devtools-mcp@latest", "--browserUrl", "http://127.0.0.1:9223",
                    ])
                }
            } else {
                claudeCommands.append([claude, "mcp", "remove", "--scope", "user", "aside"])
                claudeCommands.append([claude, "mcp", "remove", "--scope", "user", "aside-devtools"])
            }
        }

        if let codex = codexExecutable {
            if install {
                codexCommands.append([codex, "mcp", "add", "aside", "--", asidePath, "mcp"])
                if withDevTools {
                    codexCommands.append([
                        codex, "mcp", "add", "aside-devtools",
                        "--", "npx", "-y", "chrome-devtools-mcp@latest", "--browserUrl", "http://127.0.0.1:9223",
                    ])
                }
            } else {
                codexCommands.append([codex, "mcp", "remove", "aside"])
                codexCommands.append([codex, "mcp", "remove", "aside-devtools"])
            }
        }

        return AsideMCPPlan(claudeCommands: claudeCommands, codexCommands: codexCommands)
    }
}

extension ProgramaCLI {
    /// Report-only probe of Aside's Chrome DevTools Protocol endpoint. Returns the
    /// `webSocketDebuggerUrl` from `http://127.0.0.1:9223/json/version` when Aside is
    /// running, nil otherwise (including on any network/parse failure).
    func asideDevToolsEndpoint(timeout: TimeInterval = 2) -> String? {
        guard let url = URL(string: "http://127.0.0.1:9223/json/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let webSocketDebuggerUrl = json["webSocketDebuggerUrl"] as? String else { return }
            result = webSocketDebuggerUrl
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    private func asideResolveClients(environment: [String: String]) -> (claude: String?, codex: String?) {
        let searchPath = environment["PATH"]
        return (
            resolveClaudeExecutable(searchPath: searchPath),
            resolveCodexExecutable(searchPath: searchPath)
        )
    }

    private func asideIsRegistered(executable: String, serverName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mcp", "get", serverName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func asideRunCommand(_ command: [String]) throws {
        guard let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "Command failed (\(process.terminationStatus)): \(command.joined(separator: " "))")
        }
    }

    func runAside(arguments: [String]) throws {
        let subcommand = arguments.first?.lowercased() ?? "help"
        let withDevTools = arguments.contains("--with-devtools")
        let skipConfirm = arguments.contains("--yes") || arguments.contains("-y")
        let environment = ProcessInfo.processInfo.environment

        let asidePath = AsideCLILocator.resolve(environment: environment) { FileManager.default.isExecutableFile(atPath: $0) }
        let (claudeExecutable, codexExecutable) = asideResolveClients(environment: environment)

        switch subcommand {
        case "status":
            if let asidePath {
                print("Aside CLI: \(asidePath)")
            } else {
                print("Aside CLI: not found, install from https://docs.aside.com/help/developers")
            }
            if let endpoint = asideDevToolsEndpoint() {
                print("DevTools: \(endpoint)")
            } else {
                print("DevTools: not reachable (is Aside running?)")
            }
            if let claudeExecutable {
                let registered = asideIsRegistered(executable: claudeExecutable, serverName: "aside")
                print("Claude Code: \(claudeExecutable): aside \(registered ? "registered" : "not registered")")
            } else {
                print("Claude Code: not found")
            }
            if let codexExecutable {
                let registered = asideIsRegistered(executable: codexExecutable, serverName: "aside")
                print("Codex: \(codexExecutable): aside \(registered ? "registered" : "not registered")")
            } else {
                print("Codex: not found")
            }
            return

        case "install-mcp", "uninstall-mcp":
            let install = subcommand == "install-mcp"
            guard let asidePath else {
                throw CLIError(message: "Aside CLI not found. Install it from https://docs.aside.com/help/developers")
            }
            if claudeExecutable == nil, codexExecutable == nil {
                throw CLIError(message: "Neither Claude Code nor Codex CLI was found on PATH.")
            }

            print("Aside CLI: \(asidePath)")
            if let endpoint = asideDevToolsEndpoint() {
                print("DevTools: \(endpoint)")
            }
            if claudeExecutable == nil {
                print("Claude Code: not found, skipping")
            }
            if codexExecutable == nil {
                print("Codex: not found, skipping")
            }

            let plan = AsideMCPPlan.build(
                asidePath: asidePath,
                claudeExecutable: claudeExecutable,
                codexExecutable: codexExecutable,
                withDevTools: withDevTools,
                install: install
            )

            var pendingCommands: [(client: String, serverName: String, command: [String])] = []
            for command in plan.claudeCommands {
                let serverName = command.contains("aside-devtools") ? "aside-devtools" : "aside"
                pendingCommands.append((client: "Claude Code", serverName: serverName, command: command))
            }
            for command in plan.codexCommands {
                let serverName = command.contains("aside-devtools") ? "aside-devtools" : "aside"
                pendingCommands.append((client: "Codex", serverName: serverName, command: command))
            }

            guard !pendingCommands.isEmpty else {
                print("Nothing to do.")
                return
            }

            print("")
            print("The following commands will run:")
            for entry in pendingCommands {
                print("  \(entry.command.joined(separator: " "))")
            }

            if !skipConfirm {
                print("Apply these changes? [Y/n] ", terminator: "")
                if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   !response.isEmpty && response != "y" && response != "yes" {
                    print("Aborted.")
                    return
                }
            }

            for entry in pendingCommands {
                if install, let executable = entry.command.first,
                   asideIsRegistered(executable: executable, serverName: entry.serverName) {
                    print("\(entry.client): \(entry.serverName) already registered, skipping")
                    continue
                }
                print("Running: \(entry.command.joined(separator: " "))")
                try asideRunCommand(entry.command)
            }
            print("")
            print(install ? "Installed." : "Removed.")
            return

        default:
            print("Usage: programa aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]")
            throw CLIError(message: "Unknown aside subcommand: \(subcommand)")
        }
    }
}
