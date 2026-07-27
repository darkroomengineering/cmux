/// The only JSON-RPC methods the mobile bridge will forward to Programa's
/// control socket. Everything else — including destructive methods like
/// `worktree.remove` and `browser.navigate` — is rejected before it ever
/// reaches the socket.
///
/// This is the bridge's core security boundary: the control socket has no
/// notion of a restricted "mobile" client, so enforcement lives entirely
/// here. Do not widen this list without a matching change to the M1 plan.
enum MethodAllowList {
    static let allowed: Set<String> = [
        "system.ping",
        "workspace.list",
        "surface.list",
        "subscribe",
        "unsubscribe",
        "agent.prompt",
        "surface.send_text",
        "surface.send_key",
    ]

    static func isAllowed(_ method: String) -> Bool {
        allowed.contains(method)
    }
}
