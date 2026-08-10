import MCP

/// Server identity + capability declaration for `programa-mcp`.
enum ProgramaMCPServerInfo {
    /// The name reported to MCP clients in the `initialize` handshake.
    static let name = "programa"

    /// The version reported to MCP clients in the `initialize` handshake.
    ///
    /// Deliberately independent of the app's marketing version: the sidecar and
    /// the app it connects to can ship out of sync, so conflating the two would
    /// misreport which side a client is actually talking to.
    static let version = "0.1.0"
}

enum ProgramaMCPCapabilities {
    /// Capability set advertised at `initialize` time.
    ///
    /// `listChanged` is false on both: the catalogs are static tables compiled
    /// into the binary, and resources are read on demand rather than pushed, so
    /// there is no change notification for a client to subscribe to.
    static func make() -> Server.Capabilities {
        .init(
            resources: .init(subscribe: false, listChanged: false),
            tools: .init(listChanged: false)
        )
    }
}
