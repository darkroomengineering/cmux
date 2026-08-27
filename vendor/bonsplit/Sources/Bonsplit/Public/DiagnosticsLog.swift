import Darwin
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
    typealias FileHandleOpener = (URL) -> FileHandle?
    typealias FileRotator = (URL, URL) -> Bool

    public static let shared = DiagnosticsLog()

    /// 2 MB cap before rotation to `<name>.1`.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    /// Bounds records written to a handle whose path was removed externally.
    static let pathValidationRecordInterval = 64
    /// Avoids a failed filesystem rotation becoming per-record close/open churn.
    private static let rotationRetryRecordInterval = 64

    private let queue = DispatchQueue(label: "programa.diagnostics-log", qos: .utility)
    private let fileURL: URL
    private let rotatedURL: URL
    private let fileHandleOpener: FileHandleOpener
    private let fileRotator: FileRotator
    private var currentBytes: UInt64
    private var activeHandle: FileHandle?
    private var directoryIsReady = false
    private var recordsSincePathValidation = 0
    private var rotationRetryRecordCountdown = 0

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
    public convenience init(fileURL: URL) {
        self.init(
            fileURL: fileURL,
            fileHandleOpener: { FileHandle(forWritingAtPath: $0.path) },
            fileRotator: Self.replaceFileAtomically
        )
    }

    init(
        fileURL: URL,
        fileHandleOpener: @escaping FileHandleOpener,
        fileRotator: @escaping FileRotator = DiagnosticsLog.replaceFileAtomically
    ) {
        self.fileURL = fileURL
        self.rotatedURL = fileURL.deletingPathExtension()
            .appendingPathExtension(fileURL.pathExtension.isEmpty ? "1" : fileURL.pathExtension + ".1")
        self.fileHandleOpener = fileHandleOpener
        self.fileRotator = fileRotator
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.currentBytes = (attrs?[.size] as? UInt64) ?? 0
    }

    /// Logs `category message` on the diagnostics queue. Never blocks the caller.
    public func log(_ category: String, _ message: String) {
        let ts = Self.formatter.string(from: Date())
        // One record per line, always: embedded newlines in logged values (e.g. a
        // hostile path in an env override) must not be able to forge records.
        let sanitized = message.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let line = "\(ts) \(category) \(sanitized)\n"
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }

            validateActivePathIfNeeded()

            if currentBytes + UInt64(data.count) > Self.maxBytes,
               rotationRetryRecordCountdown == 0 {
                rotate()
            }

            guard let handle = openHandleIfNeeded() else { return }
            do {
                try handle.write(contentsOf: data)
                currentBytes += UInt64(data.count)
                recordsSincePathValidation += 1
                if rotationRetryRecordCountdown > 0 {
                    rotationRetryRecordCountdown -= 1
                }
            } catch {
                closeActiveHandle()
                directoryIsReady = false
            }
        }
    }

    /// Blocks until every queued best-effort write has been attempted, then asks the
    /// active handle to synchronize. Test seam; also safe before collecting a bug report.
    public func flush() {
        queue.sync {
            try? activeHandle?.synchronize()
        }
    }

    /// Runs on `queue`. Overwrites the previous rotated file and resets the byte counter.
    private func rotate() {
        closeActiveHandle()
        if fileRotator(fileURL, rotatedURL) {
            currentBytes = 0
            rotationRetryRecordCountdown = 0
        } else {
            directoryIsReady = false
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            currentBytes = (attrs?[.size] as? UInt64) ?? 0
            rotationRetryRecordCountdown = Self.rotationRetryRecordInterval
        }
    }

    /// POSIX rename replaces the prior `.1` path atomically. A failed rename leaves
    /// both the current log and the last readable backup untouched.
    private static func replaceFileAtomically(source: URL, destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return Darwin.rename(sourcePath, destinationPath) == 0
            }
        }
    }

    /// Runs on `queue`. The directory check, file creation, and seek happen once per
    /// active file rather than once per log record.
    private func openHandleIfNeeded() -> FileHandle? {
        if let activeHandle { return activeHandle }

        if !directoryIsReady {
            let directory = fileURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directoryIsReady = true
            } catch {
                directoryIsReady = false
                return nil
            }
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
        }

        guard let handle = fileHandleOpener(fileURL) else {
            directoryIsReady = false
            return nil
        }
        do {
            try handle.seekToEnd()
            activeHandle = handle
            recordsSincePathValidation = 0
            return handle
        } catch {
            try? handle.close()
            directoryIsReady = false
            return nil
        }
    }

    /// Runs on `queue`. A periodic path check catches external directory deletion
    /// without putting a filesystem lookup back on every log record.
    private func validateActivePathIfNeeded() {
        guard activeHandle != nil,
              recordsSincePathValidation + 1 >= Self.pathValidationRecordInterval else { return }
        recordsSincePathValidation = 0
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            closeActiveHandle()
            directoryIsReady = false
            currentBytes = 0
            rotationRetryRecordCountdown = 0
            return
        }
    }

    /// Runs on `queue` before rotation or after a write failure.
    private func closeActiveHandle() {
        guard let activeHandle else { return }
        try? activeHandle.close()
        self.activeHandle = nil
    }
}

/// Convenience free function mirroring `dlog`, but always-on (no `#if DEBUG`).
public func dilog(_ category: String, _ message: String) {
    DiagnosticsLog.shared.log(category, message)
}
