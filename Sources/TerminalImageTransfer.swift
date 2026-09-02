import Foundation
import AppKit

enum TerminalImageTransferMode {
    case paste
    case drop
}

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case reject
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case reject
}

enum TerminalImageTransferExecutionError: Error {
    case cancelled
}

final class TerminalImageTransferOperation: @unchecked Sendable {
    private enum State {
        case running
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .running
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func installCancellationHandler(_ handler: @escaping () -> Void) {
        var invokeImmediately = false
        lock.lock()
        switch state {
        case .running:
            cancellationHandler = handler
        case .cancelled:
            invokeImmediately = true
        case .finished:
            break
        }
        lock.unlock()

        if invokeImmediately {
            handler()
        }
    }

    func clearCancellationHandler() {
        lock.lock()
        if state == .running {
            cancellationHandler = nil
        }
        lock.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        let handler: (() -> Void)?
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return false
        }
        state = .cancelled
        handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()

        handler?()
        return true
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running else { return false }
        state = .finished
        cancellationHandler = nil
        return true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
    }
}

enum TerminalImageTransferPlanner {
    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode
    ) -> TerminalImageTransferPlan {
        plan(preparedContent: prepare(pasteboard: pasteboard, mode: mode))
    }

    static func prepare(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode
    ) -> TerminalImageTransferPreparedContent {
        switch mode {
        case .paste:
            return preparePaste(pasteboard: pasteboard)
        case .drop:
            return prepareDrop(pasteboard: pasteboard)
        }
    }

    static func plan(
        preparedContent: TerminalImageTransferPreparedContent
    ) -> TerminalImageTransferPlan {
        switch preparedContent {
        case .insertText(let text):
            return .insertText(text)
        case .fileURLs(let fileURLs):
            return plan(fileURLs: fileURLs)
        case .reject:
            return .reject
        }
    }

    static func plan(fileURLs: [URL]) -> TerminalImageTransferPlan {
        guard !fileURLs.isEmpty else { return .reject }
        return .insertText(insertedText(for: fileURLs))
    }

    static func escapeForShell(_ value: String) -> String {
        GhosttyPasteboardHelper.escapeForShell(value)
    }

    private static func insertedText(for fileURLs: [URL]) -> String {
        fileURLs
            .map { escapeForShell($0.path) }
            .joined(separator: " ")
    }

    private static func preparePaste(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let string = GhosttyPasteboardHelper.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return .fileURLs([imageURL])
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        return .reject
    }

    private static func prepareDrop(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = materializedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .insertText(string)
        }

        return .reject
    }

    private static func materializedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls
        }
        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return [imageURL]
        }
        return []
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.filter(\.isFileURL)
    }
}
