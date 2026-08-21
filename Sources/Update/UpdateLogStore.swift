import Foundation
import AppKit

final class UpdateLogStore {
    static let shared = UpdateLogStore()

    private let queue = DispatchQueue(label: "programa.update.log")
    private var entries: [String] = []
    private let maxEntries = 200
    private let maxLogFileSize: UInt64 = 1024 * 1024
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/programa-update.log")
        ensureLogFile()
    }

    func append(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let bundle = Bundle.main.bundleIdentifier ?? "<no.bundle.id>"
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [\(bundle):\(pid)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        rotateLogIfNeeded(appendingByteCount: data.count)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func rotateLogIfNeeded(appendingByteCount: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize > 0,
              currentSize + UInt64(appendingByteCount) > maxLogFileSize else {
            return
        }

        let backupURL = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        do {
            try FileManager.default.moveItem(at: logURL, to: backupURL)
            ensureLogFile()
        } catch {
            // Best-effort logging must not interfere with the updater.
        }
    }
}

final class FocusLogStore {
    static let shared = FocusLogStore()

    private let queue = DispatchQueue(label: "programa.focus.log")
    private var entries: [String] = []
    private let maxEntries = 400
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/programa-focus.log")
        ensureLogFile()
    }

    func append(_ message: String) {
        #if DEBUG
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
        #endif
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
