import Foundation

/// Always-on, local-only diagnostics log for Release builds.
///
/// Unlike `DebugEventLog` (Debug-only, in-memory ring buffer), this facility is compiled
/// into every build configuration and exists specifically so real user-reported issues
/// (e.g. "sockets keep disconnecting") leave evidence on disk even outside a debug session.
/// Nothing here ever leaves the machine: it is a plain file append, no network calls.
///
/// Safe to call from any thread, including hot paths (socket accept/teardown, render loop):
/// the public `log` call never does file I/O on the caller's thread — it only formats a
/// timestamp and enqueues the write onto a dedicated serial `.utility` queue.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    /// 2 MB cap before rotation to `<name>.1`.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "programa.diagnostics-log", qos: .utility)
    private let fileURL: URL
    private let rotatedURL: URL
    private var currentBytes: UInt64

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func resolveLogPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = env["PROGRAMA_DIAGNOSTICS_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/Programa/diagnostics.log").path
    }

    convenience init() {
        self.init(fileURL: URL(fileURLWithPath: Self.resolveLogPath()))
    }

    /// Testable initializer: point the log at an arbitrary file path.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.rotatedURL = fileURL.deletingPathExtension()
            .appendingPathExtension(fileURL.pathExtension.isEmpty ? "1" : fileURL.pathExtension + ".1")
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.currentBytes = (attrs?[.size] as? UInt64) ?? 0
    }

    /// Logs `category message` on the diagnostics queue. Never blocks the caller.
    public func log(_ category: String, _ message: String) {
        let ts = Self.formatter.string(from: Date())
        let line = "\(ts) \(category) \(message)\n"
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }

            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            if currentBytes + UInt64(data.count) > Self.maxBytes {
                rotate()
            }

            if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
            }
            currentBytes += UInt64(data.count)
        }
    }

    /// Runs on `queue`. Overwrites the previous rotated file and resets the byte counter.
    private func rotate() {
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        currentBytes = 0
    }
}

/// Convenience free function mirroring `dlog`, but always-on (no `#if DEBUG`).
public func dilog(_ category: String, _ message: String) {
    DiagnosticsLog.shared.log(category, message)
}
