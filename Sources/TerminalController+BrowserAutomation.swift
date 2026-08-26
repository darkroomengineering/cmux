// Extracted from TerminalController.swift (nuclear-review TC3): the v2 browser-automation surface (~3,700 lines) shares no logic with terminal/surface/workspace handling.
import AppKit
import Carbon.HIToolbox
import Darwin
@preconcurrency import Foundation
import Bonsplit
import WebKit

@MainActor
private final class BrowserDownloadWaitState {
    let surfaceId: UUID
    let finish: ([String: Any]) -> Void
    var observer: NSObjectProtocol?
    private var completed = false

    init(surfaceId: UUID, finish: @escaping ([String: Any]) -> Void) {
        self.surfaceId = surfaceId
        self.finish = finish
    }

    func receive(_ note: Notification) {
        guard !completed else { return }
        guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
              candidateSurfaceId == surfaceId,
              let event = note.userInfo?["event"] as? [String: Any] else {
            return
        }
        completed = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        finish(event)
    }

    func install(_ observer: NSObjectProtocol) {
        if completed {
            NotificationCenter.default.removeObserver(observer)
        } else {
            self.observer = observer
        }
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

extension TerminalController {
    // MARK: - V2 Browser Methods

    enum V2BrowserFrameSelectorSource {
        case frameSelect
        case stateLoad
    }

    enum V2BrowserFrameSelectorApplyResult {
        case applied
        case rejected(limit: Int)
    }

    struct V2BrowserStateRestoreLimits {
        let documentByteLimit: Int
        let urlByteLimit: Int
        let cookieCountLimit: Int
        let storageEntryCountLimit: Int
        let storageKeyByteLimit: Int
        let storageValueByteLimit: Int
        let frameSelectorByteLimit: Int

        static let standard = V2BrowserStateRestoreLimits(
            documentByteLimit: 8 * 1_024 * 1_024,
            urlByteLimit: 16 * 1_024,
            cookieCountLimit: 1_024,
            storageEntryCountLimit: 4_096,
            storageKeyByteLimit: 4 * 1_024,
            storageValueByteLimit: 1_024 * 1_024,
            frameSelectorByteLimit: 16 * 1_024
        )
    }

    enum V2BrowserStateStepOutcome {
        case succeeded
        case timedOut
        case failed(message: String)
        case originMismatch(message: String)
        case unavailable(message: String)
    }

    struct V2BrowserStateNavigationMilestone {
        let navigationID: UUID
        let url: URL
        let executionURL: URL

        init(navigationID: UUID, url: URL, executionURL: URL? = nil) {
            self.navigationID = navigationID
            self.url = url
            self.executionURL = executionURL ?? url
        }
    }

    enum V2BrowserStateNavigationOutcome {
        case finished(
            committed: V2BrowserStateNavigationMilestone,
            finished: V2BrowserStateNavigationMilestone
        )
        case cancelled
        case timedOut
        case failed(message: String)
        case permissionDenied
        case unavailable
        case busy
    }

    struct V2BrowserStateStoragePayload {
        let expectedOrigin: String
        let executionOrigin: String
        let local: [String: String]
        let session: [String: String]
    }

    struct V2BrowserStateRestoreOperations {
        let installCookies: ([HTTPCookie], URL) -> V2BrowserStateStepOutcome
        let navigateAndWait: (URL) -> V2BrowserStateNavigationOutcome
        let applyStorage: (V2BrowserStateStoragePayload) -> V2BrowserStateStepOutcome
        let applyFrameSelector: (String?) -> V2BrowserStateStepOutcome
        let leaseIsValid: () -> Bool
        let cancelNavigation: () -> Void
    }

    final class V2BrowserStateRestoreLeaseCoordinator {
        enum DataStoreLeaseState: String, Equatable {
            case available
            case activeRestore = "active_restore"
            /// WebKit has accepted a mutation whose callback has not drained. This remains
            /// fail-closed, potentially until process restart, because releasing without the
            /// callback would let a late mutation overlap a newer restore.
            case taintedByUndrainedMutationCallbacks = "tainted_by_undrained_mutation_callbacks"
        }

        struct Lease {
            fileprivate let token: UUID
            fileprivate let dataStoreID: ObjectIdentifier
            fileprivate let generation: UUID
        }

        private struct ActiveLease {
            let lease: Lease
            var pendingMutationCount = 0
            var releaseRequested = false
        }

        static let shared = V2BrowserStateRestoreLeaseCoordinator()

        private let lock = NSLock()
        private var activeLeases: [ObjectIdentifier: ActiveLease] = [:]

        func acquire(dataStoreID: ObjectIdentifier, generation: UUID) -> Lease? {
            lock.lock()
            defer { lock.unlock() }
            guard activeLeases[dataStoreID] == nil else { return nil }
            let lease = Lease(token: UUID(), dataStoreID: dataStoreID, generation: generation)
            activeLeases[dataStoreID] = ActiveLease(lease: lease)
            return lease
        }

        func state(dataStoreID: ObjectIdentifier) -> DataStoreLeaseState {
            lock.lock()
            defer { lock.unlock() }
            guard let active = activeLeases[dataStoreID] else { return .available }
            return active.releaseRequested
                ? .taintedByUndrainedMutationCallbacks
                : .activeRestore
        }

        func isValid(_ lease: Lease, currentGeneration: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard currentGeneration == lease.generation,
                  let active = activeLeases[lease.dataStoreID] else { return false }
            return active.lease.token == lease.token && !active.releaseRequested
        }

        func beginPendingMutation(_ lease: Lease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token,
                  !active.releaseRequested else { return false }
            active.pendingMutationCount += 1
            activeLeases[lease.dataStoreID] = active
            return true
        }

        @discardableResult
        func endPendingMutation(_ lease: Lease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token,
                  active.pendingMutationCount > 0 else { return false }
            active.pendingMutationCount -= 1
            if active.pendingMutationCount == 0, active.releaseRequested {
                activeLeases.removeValue(forKey: lease.dataStoreID)
            } else {
                activeLeases[lease.dataStoreID] = active
            }
            return true
        }

        func release(_ lease: Lease) {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token else { return }
            if active.pendingMutationCount == 0 {
                activeLeases.removeValue(forKey: lease.dataStoreID)
            } else {
                active.releaseRequested = true
                activeLeases[lease.dataStoreID] = active
            }
        }
    }

    struct V2BrowserStateRestoreFailure: Error, Equatable {
        enum Code: Equatable {
            case documentReadFailed
            case documentNotRegular
            case documentTooLarge
            case malformedDocument
            case unsupportedSchemaVersion
            case invalidURL
            case invalidCookie
            case duplicateCookie
            case cookieLimitExceeded
            case storageEntryLimitExceeded
            case storageKeyTooLarge
            case storageValueTooLarge
            case frameSelectorTooLarge
            case originMismatch
            case navigationMismatch
            case navigationCancelled
            case navigationFailed
            case navigationTimedOut
            case navigationPermissionDenied
            case navigationUnavailable
            case surfaceUnavailable
            case navigationBusy
            case restoreInvalidated
            case cookieInstallTimedOut
            case cookieInstallFailed
            case storageApplyTimedOut
            case storageApplyFailed
            case frameSelectorApplyTimedOut
            case frameSelectorApplyFailed
        }

        let code: Code
        let message: String
        let cookiesMayHaveBeenMutated: Bool
        let cookieCount: Int
        let storageMayHaveBeenMutated: Bool

        init(
            code: Code,
            message: String,
            cookiesMayHaveBeenMutated: Bool = false,
            cookieCount: Int = 0,
            storageMayHaveBeenMutated: Bool = false
        ) {
            self.code = code
            self.message = message
            self.cookiesMayHaveBeenMutated = cookiesMayHaveBeenMutated
            self.cookieCount = cookieCount
            self.storageMayHaveBeenMutated = storageMayHaveBeenMutated
        }
    }

    enum V2BrowserStateRestorer {
        static let currentSchemaVersion = 1

        struct PreparedState {
            let targetURL: URL
            let cookies: [HTTPCookie]
            let storage: V2BrowserStateStoragePayload
            let frameSelector: String?
        }

        static func restore(
            fileURL: URL,
            limits: V2BrowserStateRestoreLimits = .standard,
            using operations: V2BrowserStateRestoreOperations
        ) -> Result<Void, V2BrowserStateRestoreFailure> {
            switch prepare(fileURL: fileURL, limits: limits) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let state):
                return execute(state, using: operations)
            }
        }

        static func prepare(
            fileURL: URL,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<PreparedState, V2BrowserStateRestoreFailure> {
            let byteLimit = max(0, limits.documentByteLimit)
            let readCount: Int
            let (limitPlusOne, overflow) = byteLimit.addingReportingOverflow(1)
            readCount = overflow ? Int.max : limitPlusOne

            let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentReadFailed,
                        message: String(cString: strerror(errno))
                    )
                )
            }
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(descriptor)
                return .failure(failure(.documentReadFailed, message))
            }
            guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(descriptor)
                return .failure(
                    failure(.documentNotRegular, "Browser state path must identify a regular file")
                )
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }

            let data: Data
            do {
                data = try handle.read(upToCount: readCount) ?? Data()
            } catch {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentReadFailed,
                        message: error.localizedDescription
                    )
                )
            }

            return prepare(data: data, limits: limits)
        }

        static func prepare(
            data: Data,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<PreparedState, V2BrowserStateRestoreFailure> {
            let byteLimit = max(0, limits.documentByteLimit)

            guard data.count <= byteLimit else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentTooLarge,
                        message: "Browser state document exceeds \(byteLimit) bytes"
                    )
                )
            }

            let raw: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state document must be a JSON object"
                        )
                    )
                }
                raw = object
            } catch {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .malformedDocument,
                        message: error.localizedDescription
                    )
                )
            }

            if let rawSchemaVersion = raw["schema_version"] {
                guard let schemaVersion = rawSchemaVersion as? NSNumber,
                      CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
                      schemaVersion.doubleValue == Double(schemaVersion.intValue),
                      schemaVersion.intValue == currentSchemaVersion else {
                    return .failure(
                        failure(.unsupportedSchemaVersion, "Unsupported browser state schema version")
                    )
                }
            }

            guard let rawURL = raw["url"] as? String,
                  !rawURL.isEmpty,
                  rawURL.utf8.count <= max(0, limits.urlByteLimit),
                  let targetURL = URL(string: rawURL),
                  originString(for: targetURL) != nil else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .invalidURL,
                        message: "Browser state URL must be an absolute HTTP or HTTPS URL"
                    )
                )
            }

            let cookieRows: [[String: Any]]
            if let rawCookies = raw["cookies"] {
                guard let rows = rawCookies as? [[String: Any]] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state cookies must be an array of objects"
                        )
                    )
                }
                cookieRows = rows
            } else {
                cookieRows = []
            }
            guard cookieRows.count <= max(0, limits.cookieCountLimit) else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieLimitExceeded,
                        message: "Browser state cookie count exceeds \(max(0, limits.cookieCountLimit))"
                    )
                )
            }

            var cookies: [HTTPCookie] = []
            cookies.reserveCapacity(cookieRows.count)
            var cookieIdentities = Set<String>()
            for row in cookieRows {
                guard let cookie = makeCookie(from: row, fallbackURL: targetURL) else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .invalidCookie,
                            message: "Browser state contains an invalid cookie"
                        )
                    )
                }
                let normalizedDomain = cookie.domain
                    .lowercased()
                    .drop(while: { $0 == "." })
                let identity = "\(normalizedDomain)\u{0}\(cookie.name)\u{0}\(cookie.path)"
                guard cookieIdentities.insert(identity).inserted else {
                    return .failure(
                        failure(.duplicateCookie, "Browser state contains duplicate cookie identities")
                    )
                }
                cookies.append(cookie)
            }

            let storageObject: [String: Any]
            if let rawStorage = raw["storage"] {
                guard let dictionary = rawStorage as? [String: Any] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state storage must be an object"
                        )
                    )
                }
                storageObject = dictionary
            } else {
                storageObject = [:]
            }

            let localStorage: [String: String]
            switch storageMap(named: "local", in: storageObject, limits: limits) {
            case .success(let map):
                localStorage = map
            case .failure(let failure):
                return .failure(failure)
            }
            let sessionStorage: [String: String]
            switch storageMap(named: "session", in: storageObject, limits: limits) {
            case .success(let map):
                sessionStorage = map
            case .failure(let failure):
                return .failure(failure)
            }

            let frameSelector: String?
            if let rawFrameSelector = raw["frame_selector"], !(rawFrameSelector is NSNull) {
                guard let selector = rawFrameSelector as? String else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state frame selector must be a string or null"
                        )
                    )
                }
                guard selector.utf8.count <= max(0, limits.frameSelectorByteLimit) else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .frameSelectorTooLarge,
                            message: "Browser state frame selector exceeds \(max(0, limits.frameSelectorByteLimit)) bytes"
                        )
                    )
                }
                frameSelector = selector.isEmpty ? nil : selector
            } else {
                frameSelector = nil
            }

            guard let expectedOrigin = originString(for: targetURL) else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .invalidURL,
                        message: "Browser state URL has no storage origin"
                    )
                )
            }
            return .success(
                PreparedState(
                    targetURL: targetURL,
                    cookies: cookies,
                    storage: V2BrowserStateStoragePayload(
                        expectedOrigin: expectedOrigin,
                        executionOrigin: expectedOrigin,
                        local: localStorage,
                        session: sessionStorage
                    ),
                    frameSelector: frameSelector
                )
            )
        }

        static func encodeDocument(
            url: URL?,
            cookies: [[String: Any]],
            storage: Any,
            frameSelector: String?,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<Data, V2BrowserStateRestoreFailure> {
            // Saved state is origin-bound. Blank/about:blank tabs intentionally fail URL
            // validation so every reported save success is loadable by the same contract.
            let raw: [String: Any] = [
                "schema_version": currentSchemaVersion,
                "url": url?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storage,
                "frame_selector": frameSelector ?? NSNull(),
            ]
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: raw,
                    options: [.prettyPrinted, .sortedKeys]
                )
                switch prepare(data: data, limits: limits) {
                case .success:
                    return .success(data)
                case .failure(let failure):
                    return .failure(failure)
                }
            } catch {
                return .failure(failure(.malformedDocument, error.localizedDescription))
            }
        }

        static func execute(
            _ state: PreparedState,
            using operations: V2BrowserStateRestoreOperations
        ) -> Result<Void, V2BrowserStateRestoreFailure> {
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated"))
            }
            switch operations.installCookies(state.cookies, state.targetURL) {
            case .succeeded:
                break
            case .timedOut:
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieInstallTimedOut,
                        message: "Timed out installing browser state cookies",
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            case .failed(let message), .originMismatch(let message):
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieInstallFailed,
                        message: message,
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            case .unavailable(let message):
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .surfaceUnavailable,
                        message: message,
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            }

            let cookiesMutated = !state.cookies.isEmpty
            let cookieCount = state.cookies.count
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }

            let committed: V2BrowserStateNavigationMilestone
            let finished: V2BrowserStateNavigationMilestone
            switch operations.navigateAndWait(state.targetURL) {
            case .finished(let committedMilestone, let finishedMilestone):
                committed = committedMilestone
                finished = finishedMilestone
            case .cancelled:
                return .failure(failure(.navigationCancelled, "Browser state navigation was cancelled", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .timedOut:
                operations.cancelNavigation()
                return .failure(failure(.navigationTimedOut, "Timed out waiting for browser state navigation", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .failed(let message):
                return .failure(failure(.navigationFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .permissionDenied:
                return .failure(failure(.navigationPermissionDenied, "Insecure HTTP navigation is not allowed", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .unavailable:
                return .failure(failure(.navigationUnavailable, "Browser surface became unavailable", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .busy:
                return .failure(failure(.navigationBusy, "Another browser state navigation is active", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }

            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            guard committed.navigationID == finished.navigationID else {
                return .failure(
                    failure(
                        .navigationMismatch,
                        "Browser state navigation commit and finish do not refer to the same navigation",
                        cookiesMutated: cookiesMutated,
                        cookieCount: cookieCount
                    )
                )
            }
            guard originString(for: committed.url) == state.storage.expectedOrigin,
                  originString(for: finished.url) == state.storage.expectedOrigin else {
                return .failure(
                    failure(.originMismatch, "Browser state navigation finished on an unexpected origin", cookiesMutated: cookiesMutated, cookieCount: cookieCount)
                )
            }

            guard let committedExecutionOrigin = originString(for: committed.executionURL),
                  let finishedExecutionOrigin = originString(for: finished.executionURL),
                  committedExecutionOrigin == finishedExecutionOrigin else {
                return .failure(failure(.originMismatch, "Browser state navigation execution origin changed", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            let storage = V2BrowserStateStoragePayload(
                expectedOrigin: state.storage.expectedOrigin,
                executionOrigin: finishedExecutionOrigin,
                local: state.storage.local,
                session: state.storage.session
            )
            switch operations.applyStorage(storage) {
            case .succeeded:
                break
            case .timedOut:
                return .failure(failure(.storageApplyTimedOut, "Timed out applying browser storage", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .failed(let message):
                return .failure(failure(.storageApplyFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .originMismatch(let message):
                return .failure(failure(.originMismatch, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .unavailable(let message):
                return .failure(failure(.surfaceUnavailable, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }

            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }
            switch operations.applyFrameSelector(state.frameSelector) {
            case .succeeded:
                return .success(())
            case .timedOut:
                return .failure(failure(.frameSelectorApplyTimedOut, "Timed out applying frame selector", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .failed(let message), .originMismatch(let message):
                return .failure(failure(.frameSelectorApplyFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .unavailable(let message):
                return .failure(failure(.surfaceUnavailable, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }
        }

        static func originString(for url: URL) -> String? {
            guard let rawScheme = url.scheme?.lowercased(),
                  rawScheme == "http" || rawScheme == "https",
                  let rawHost = url.host?.lowercased(),
                  !rawHost.isEmpty else {
                return nil
            }
            let unbracketedHost = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let host = unbracketedHost.contains(":") ? "[\(unbracketedHost)]" : unbracketedHost
            let defaultPort = rawScheme == "https" ? 443 : 80
            if let port = url.port, port != defaultPort {
                return "\(rawScheme)://\(host):\(port)"
            }
            return "\(rawScheme)://\(host)"
        }

        private static func storageMap(
            named name: String,
            in storage: [String: Any],
            limits: V2BrowserStateRestoreLimits
        ) -> Result<[String: String], V2BrowserStateRestoreFailure> {
            guard let rawMap = storage[name] else { return .success([:]) }
            guard let map = rawMap as? [String: Any] else {
                return .failure(
                    failure(.malformedDocument, "Browser state \(name) storage must be an object")
                )
            }
            guard map.count <= max(0, limits.storageEntryCountLimit) else {
                return .failure(
                    failure(
                        .storageEntryLimitExceeded,
                        "Browser state \(name) storage exceeds \(max(0, limits.storageEntryCountLimit)) entries"
                    )
                )
            }

            var validated: [String: String] = [:]
            validated.reserveCapacity(map.count)
            for (key, rawValue) in map {
                guard key.utf8.count <= max(0, limits.storageKeyByteLimit) else {
                    return .failure(
                        failure(.storageKeyTooLarge, "Browser state storage key exceeds the byte limit")
                    )
                }
                guard let value = rawValue as? String else {
                    return .failure(
                        failure(.malformedDocument, "Browser state storage values must be strings")
                    )
                }
                guard value.utf8.count <= max(0, limits.storageValueByteLimit) else {
                    return .failure(
                        failure(.storageValueTooLarge, "Browser state storage value exceeds the byte limit")
                    )
                }
                validated[key] = value
            }
            return .success(validated)
        }

        private static func makeCookie(from raw: [String: Any], fallbackURL: URL) -> HTTPCookie? {
            guard let name = raw["name"] as? String, !name.isEmpty,
                  let value = raw["value"] as? String else {
                return nil
            }

            let originURL: URL
            if let rawCookieURL = raw["url"] {
                guard let cookieURLString = rawCookieURL as? String,
                      let cookieURL = URL(string: cookieURLString),
                      originString(for: cookieURL) != nil else {
                    return nil
                }
                originURL = cookieURL
            } else {
                originURL = fallbackURL
            }

            let domain: String
            if let rawDomain = raw["domain"] {
                guard let cookieDomain = rawDomain as? String, !cookieDomain.isEmpty else { return nil }
                domain = cookieDomain
            } else {
                guard let host = originURL.host, !host.isEmpty else { return nil }
                domain = host
            }

            let path: String
            if let rawPath = raw["path"] {
                guard let cookiePath = rawPath as? String, cookiePath.hasPrefix("/") else { return nil }
                path = cookiePath
            } else {
                path = "/"
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .originURL: originURL,
                .domain: domain,
                .path: path,
            ]
            if let rawSecure = raw["secure"] {
                guard let secure = rawSecure as? Bool else { return nil }
                if secure { properties[.secure] = "TRUE" }
            }
            if let rawHTTPOnly = raw["http_only"] {
                guard let httpOnly = rawHTTPOnly as? Bool else { return nil }
                if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            }
            if let rawSameSite = raw["same_site"], !(rawSameSite is NSNull) {
                guard let sameSite = rawSameSite as? String,
                      sameSite == HTTPCookieStringPolicy.sameSiteStrict.rawValue
                        || sameSite == HTTPCookieStringPolicy.sameSiteLax.rawValue else {
                    return nil
                }
                properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite)
            }
            if let rawExpires = raw["expires"], !(rawExpires is NSNull) {
                guard let expires = rawExpires as? NSNumber,
                      CFGetTypeID(expires) != CFBooleanGetTypeID(),
                      expires.doubleValue.isFinite else {
                    return nil
                }
                properties[.expires] = Date(timeIntervalSince1970: expires.doubleValue)
            }
            return HTTPCookie(properties: properties)
        }

        private static func failure(
            _ code: V2BrowserStateRestoreFailure.Code,
            _ message: String,
            cookiesMutated: Bool = false,
            cookieCount: Int = 0,
            storageMutated: Bool = false
        ) -> V2BrowserStateRestoreFailure {
            V2BrowserStateRestoreFailure(
                code: code,
                message: message,
                cookiesMayHaveBeenMutated: cookiesMutated,
                cookieCount: cookieCount,
                storageMayHaveBeenMutated: storageMutated
            )
        }
    }

    func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    private func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    private func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is V2BrowserUndefinedSentinel {
            return [
                Self.v2BrowserEvalEnvelopeTypeKey: Self.v2BrowserEvalEnvelopeTypeUndefined,
                Self.v2BrowserEvalEnvelopeValueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    private enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    private func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        contentWorld: WKContentWorld,
        webKitCompletionDidDrain: (() -> Void)? = nil
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            if preferAsync {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                    webKitCompletionDidDrain?()
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error.localizedDescription)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    webKitCompletionDidDrain?()
                    if let error {
                        finish(nil, error.localizedDescription)
                    } else {
                        finish(value, nil)
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
            let runLoop = CFRunLoopGetCurrent()
            var resolved = false
            var timedOut = false
            var result: T?

            let finish: (T) -> Void = { value in
                guard !resolved else { return }
                resolved = true
                result = value
                CFRunLoopStop(runLoop)
            }

            start(finish)
            guard !resolved else { return result }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !resolved else { return }
                resolved = true
                timedOut = true
                CFRunLoopStop(runLoop)
            }

            CFRunLoopRun()
            return timedOut ? nil : result
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        start { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __programaEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__programaEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__programaEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true
        case .failure:
            return false
        }
    }

    func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    /// Current navigation generation for a surface. Bumped by `v2BrowserBumpNavigationGeneration`
    /// on every committed main-frame navigation (see `BrowserPanel.configureNavigationDelegateCallbacks`).
    func v2BrowserNavigationGeneration(forSurface surfaceId: UUID) -> UInt64 {
        v2BrowserNavigationGenerationBySurface[surfaceId] ?? 0
    }

    /// Invalidates every element ref allocated on the surface's previous page by advancing its
    /// navigation generation (M6a). Call from the single main-frame-commit choke point only —
    /// do not call per-subframe or per-provisional-navigation event.
    func v2BrowserBumpNavigationGeneration(forSurface surfaceId: UUID) {
        v2BrowserNavigationGenerationBySurface[surfaceId, default: 0] += 1
    }

    func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(v2BrowserNextElementOrdinal)"
        v2BrowserNextElementOrdinal += 1
        v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(
            surfaceId: surfaceId,
            selector: selector,
            navigationGeneration: v2BrowserNavigationGeneration(forSurface: surfaceId)
        )
        return ref
    }

    private enum V2BrowserSelectorLookup {
        case literal(String)
        case notFound
        case stale
    }

    /// Single shared resolve helper backing both `v2BrowserResolveSelector` (used by every
    /// click/type/query consumer) and `v2BrowserSelectorResolutionError` (the structured error
    /// to surface when resolution fails). Distinguishes a ref that once resolved but whose
    /// surface has since navigated (`.stale`) from any other miss (`.notFound`) so callers can
    /// report `stale_element` instead of a generic `not_found` (M6a).
    private func v2BrowserLookupSelector(_ rawSelector: String, surfaceId: UUID) -> V2BrowserSelectorLookup {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        guard let refKey else { return .literal(trimmed) }

        guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else {
            return .notFound
        }
        guard entry.navigationGeneration == v2BrowserNavigationGeneration(forSurface: surfaceId) else {
            return .stale
        }
        return .literal(entry.selector)
    }

    func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        if case .literal(let selector) = v2BrowserLookupSelector(rawSelector, surfaceId: surfaceId) {
            return selector
        }
        return nil
    }

    /// Error to return when `v2BrowserResolveSelector` returns nil for `rawSelector` against
    /// `surfaceId`. Every consumer of the element-ref maps (resolve/click/type/query paths)
    /// should surface this instead of hand-rolling a generic not_found, so a stale ref reports
    /// `stale_element` rather than being indistinguishable from "never allocated".
    func v2BrowserSelectorResolutionError(_ rawSelector: String, surfaceId: UUID) -> V2CallResult {
        switch v2BrowserLookupSelector(rawSelector, surfaceId: surfaceId) {
        case .stale:
            return .err(
                code: "stale_element",
                message: "element ref was captured on a previous page",
                data: ["ref": rawSelector]
            )
        case .notFound, .literal:
            return .err(code: "not_found", message: "Element reference not found", data: ["selector": rawSelector])
        }
    }

    func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    @discardableResult
    func v2BrowserApplyFrameSelector(
        _ selector: String?,
        surfaceId: UUID,
        source: V2BrowserFrameSelectorSource
    ) -> V2BrowserFrameSelectorApplyResult {
        _ = source
        guard let selector, !selector.isEmpty else {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .applied
        }
        guard selector.utf8.count <= Self.v2BrowserElementRefSelectorByteLimit else {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .rejected(limit: Self.v2BrowserElementRefSelectorByteLimit)
        }
        v2BrowserFrameSelectorBySurface[surfaceId] = selector
        return .applied
    }

    private func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2JavaScriptResult {
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __programaDoc = document;
            try {
              const __programaFrame = document.querySelector(\(selectorLiteral));
              if (__programaFrame && __programaFrame.contentDocument) {
                __programaDoc = __programaFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __programaDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __programaMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __programaEvalInFrame = async function() {
          const document = __programaDoc;
          \(executionBlock)
          const __value = await __programaMaybeAwait(__r);
          return {
            __programa_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __programa_v: __value
          };
        };

        return await __programaEvalInFrame();
        """

        var rawResult = v2RunJavaScript(
            webView,
            script: asyncFunctionBody,
            timeout: timeout,
            preferAsync: true,
            contentWorld: .page
        )

        if !useEval, case .failure(let pageMessage) = rawResult {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .defaultClient
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    private func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

    func v2MarkdownOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        // Resolve the path (expand ~ and standardize)
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        // Reject paths that aren't absolute after resolution
        guard filePath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(filePath)", data: ["path": filePath])
        }

        // Validate the file exists and is a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory, not a file: \(filePath)", data: ["path": filePath])
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return .err(code: "permission_denied", message: "File not readable: \(filePath)", data: ["path": filePath])
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let directionStr = v2String(params, "direction") ?? "right"
            guard let direction = parseSplitDirection(directionStr) else {
                result = .err(code: "invalid_params", message: "Invalid direction '\(directionStr)' (left|right|up|down)", data: nil)
                return
            }
            let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .up)

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath,
                focus: v2FocusAllowed()
            )

            guard let markdownPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": markdownPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "path": filePath
            ])
        }
        return result
    }

    // MARK: - Browser

    func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let url,
               respectExternalOpenRules,
               BrowserLinkOpenSettings.shouldOpenExternally(url) {
                guard NSWorkspace.shared.open(url) else {
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                }
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(nil),
                    "pane_ref": v2Ref(kind: .pane, uuid: nil),
                    "surface_id": v2OrNull(nil),
                    "surface_ref": v2Ref(kind: .surface, uuid: nil),
                    "created_split": false,
                    "placement_strategy": "external",
                    "opened_externally": true,
                    "url": url.absoluteString
                ])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredBrowserTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(inPane: targetPane, url: url, focus: true)
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(from: sourceSurfaceId, orientation: .horizontal, url: url)
            }

            guard let browserPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": browserPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: browserPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "created_split": createdSplit,
                "placement_strategy": placementStrategy
            ])
        }
        return result
    }

    func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            browserPanel.navigateSmart(url)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let selectorLiteral = v2JSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: data)
    }

    func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, useEval: false) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ws.id.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard v2WaitForBrowserCondition(
                            browserPanel.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"

            let script = """
            (() => {
              const __interactiveOnly = \(interactiveLiteral);
              const __includeCursor = \(cursorLiteral);
              const __compact = \(compactLiteral);
              const __maxDepth = \(maxDepth);
              const __scopeSelector = \(scopeLiteral);

              const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
              const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
              const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
              const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

              const __isVisible = (el) => {
                try {
                  if (!el) return false;
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  if (!style || !rect) return false;
                  if (rect.width <= 0 || rect.height <= 0) return false;
                  if (style.display === 'none' || style.visibility === 'hidden') return false;
                  if (parseFloat(style.opacity || '1') <= 0.01) return false;
                  return true;
                } catch (_) {
                  return false;
                }
              };

              const __implicitRole = (el) => {
                const tag = String(el.tagName || '').toLowerCase();
                if (tag === 'button') return 'button';
                if (tag === 'a' && el.hasAttribute('href')) return 'link';
                if (tag === 'input') {
                  const type = String(el.getAttribute('type') || 'text').toLowerCase();
                  if (type === 'checkbox') return 'checkbox';
                  if (type === 'radio') return 'radio';
                  if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
                  return 'textbox';
                }
                if (tag === 'textarea') return 'textbox';
                if (tag === 'select') return 'combobox';
                if (tag === 'summary') return 'button';
                if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
                if (tag === 'li') return 'listitem';
                return null;
              };

              const __nameFor = (el) => {
                const aria = __normalize(el.getAttribute('aria-label') || '');
                if (aria) return aria;
                const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
                if (labelledBy) {
                  const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
                  if (text) return text;
                }
                if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
                  const placeholder = __normalize(el.getAttribute('placeholder') || '');
                  if (placeholder) return placeholder;
                  const value = __normalize(el.value || '');
                  if (value) return value;
                }
                const title = __normalize(el.getAttribute('title') || '');
                if (title) return title;
                const text = __normalize(el.innerText || el.textContent || '');
                if (text) return text.slice(0, 120);
                return '';
              };

              const __cssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  const parent = cur.parentElement;
                  if (parent) {
                    const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                    if (siblings.length > 1) {
                      const index = siblings.indexOf(cur) + 1;
                      part += `:nth-of-type(${index})`;
                    }
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                  if (parts.length >= 6) break;
                }
                return parts.join(' > ');
              };

              const __root = (() => {
                if (__scopeSelector) {
                  return document.querySelector(__scopeSelector) || document.body || document.documentElement;
                }
                return document.body || document.documentElement;
              })();

              const __entries = [];
              const __seen = new Set();
              const __appendEntry = (el, depth, forcedRole) => {
                if (!__isVisible(el)) return;
                const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
                const role = forcedRole || explicitRole || __implicitRole(el) || '';
                if (!role) return;

                if (__interactiveOnly && !__interactiveRoles.has(role)) return;
                if (!__interactiveOnly) {
                  const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
                  if (!includeRole) return;
                  if (__compact && __structuralRoles.has(role)) {
                    const name = __nameFor(el);
                    if (!name) return;
                  }
                }

                const selector = __cssPath(el);
                if (!selector || __seen.has(selector)) return;
                __seen.add(selector);
                __entries.push({
                  selector,
                  role,
                  name: __nameFor(el),
                  depth
                });
              };

              const __walk = (node, depth) => {
                if (!node || depth > __maxDepth || node.nodeType !== 1) return;
                const el = node;
                __appendEntry(el, depth, null);
                for (const child of Array.from(el.children || [])) {
                  __walk(child, depth + 1);
                }
              };

              if (__root) {
                __walk(__root, 0);
              }

              if (__includeCursor && __root) {
                const all = Array.from(__root.querySelectorAll('*'));
                for (const el of all) {
                  if (!__isVisible(el)) continue;
                  const style = getComputedStyle(el);
                  const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
                  const hasCursorPointer = style.cursor === 'pointer';
                  const tabIndex = el.getAttribute('tabindex');
                  const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
                  if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
                  __appendEntry(el, 0, 'generic');
                  if (__entries.length >= 256) break;
                }
              }

              const body = document.body;
              const root = document.documentElement;
              return {
                title: __normalize(document.title || ''),
                url: String(location.href || ''),
                ready_state: String(document.readyState || ''),
                text: body ? String(body.innerText || '') : '',
                html: root ? String(root.outerHTML || '') : '',
                entries: __entries
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0, useEval: false) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupResult = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                setupResult = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                setupResult = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            workspaceId = ws.id
            surfaceIdOut = surfaceId
            webView = browserPanel.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceIdOut)
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        if v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        }
        return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
    }

    func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
              el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter. Frameworks like React, Vue, and Angular override the
    /// value property on instances, so a plain `el.value = x` assignment only
    /// updates the DOM without notifying the framework's internal state.
    /// Calling the native setter from the prototype bypasses the override and
    /// triggers the framework's change-detection when followed by an `input`
    /// event. Walks the prototype chain instead of using instanceof so it
    /// works with cross-realm elements (iframes) and custom web components.
    /// Expects `el` and `newValue` to be in scope.
    private static let reactCompatibleSetValue = """
        let nativeSetter = null;
        for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { nativeSetter = desc.set; break; }
        }
        if (nativeSetter) {
          nativeSetter.call(el, newValue);
        } else {
          el.value = newValue;
        }
    """

    func v2BrowserType(params: [String: Any]) -> V2CallResult {
        guard let text = v2String(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "type") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const chunk = String(\(textLiteral));
              if ('value' in el) {
                const newValue = (el.value || '') + chunk;
                \(Self.reactCompatibleSetValue)
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = (el.textContent || '') + chunk;
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserFill(params: [String: Any]) -> V2CallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = v2RawString(params, "text") ?? v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "fill") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const newValue = String(\(textLiteral));
              if ('value' in el) {
                \(Self.reactCompatibleSetValue)
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = newValue;
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keypress', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              el.checked = \(checked ? "true" : "false");
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
        let selectedValue = v2String(params, "value") ?? v2String(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "select") { selectorLiteral in
            let valueLiteral = v2JSONLiteral(selectedValue)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('value' in el)) return { ok: false, error: 'not_select' };
              const newValue = String(\(valueLiteral));
              \(Self.reactCompatibleSetValue)
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if let selectorRaw, selector == nil {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }

            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let snapshotResult: Data?? = v2AwaitCallback(timeout: 5.0) { finish in
                browserPanel.takeSnapshot { image in
                    finish(image.flatMap { self.v2PNGData(from: $0) })
                }
            }

            guard let snapshotResult else {
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            }
            guard let imageData = snapshotResult else {
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            }

            var result: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "png_base64": imageData.base64EncodedString()
            ]

            // Best effort: keep screenshot data available even when temp-file writes fail.
            let screenshotsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
                bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
                let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
                let shortRandomId = String(UUID().uuidString.prefix(8))
                let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
                let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
                if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                    result["path"] = imageURL.path
                    result["url"] = imageURL.absoluteString
                }
            }

            return .ok(result)
        }
    }

    func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    func v2BrowserGetTitle(params: [String: Any]) -> V2CallResult {
        v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }


    func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            switch action {
            case "back":
                browserPanel.goBack()
            case "forward":
                browserPanel.goForward()
            case "reload":
                browserPanel.reload()
            default:
                break
            }
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "url": browserPanel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    func v2BrowserFocusWebView(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.0)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = .err(code: "invalid_state", message: "WebView is hidden", data: nil)
                return
            }

            window.makeFirstResponder(webView)
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                result = .ok(["focused": true])
            } else {
                result = .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
            }
        }
        return result
    }

    /// Toggles Design Mode using the same focused-panel routing rule as the React Grab keyboard
    /// shortcut (`resolveReactGrabShortcutRoute` / `activateDesignModeRoute`): no `surface_id`
    /// required, targets the focused browser panel directly, or the workspace's single browser
    /// panel when a terminal is focused.
    func v2BrowserDesignModeToggle(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(
            code: "not_found",
            message: "No browser panel available for Design Mode",
            data: nil
        )
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            if activateDesignModeRoute(in: ws) {
                result = .ok(["toggled": true])
            }
        }
        return result
    }

    func v2BrowserIsWebViewFocused(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var focused = false
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            let webView = browserPanel.webView
            guard let window = webView.window,
                  let fr = window.firstResponder as? NSView else {
                focused = false
                return
            }
            focused = fr.isDescendant(of: webView)
        }
        return .ok(["focused": focused])
    }

    func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any] = [:]
    ) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let script = """
            (() => {
              const __programaCssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
                  if (siblings.length > 1) {
                    const pos = siblings.indexOf(cur) + 1;
                    part += `:nth-of-type(${pos})`;
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                }
                return parts.join(' > ');
              };

              const __programaFound = (() => {
            \(finderBody)
              })();
              if (!__programaFound) return { ok: false, error: 'not_found' };
              const selector = __programaCssPath(__programaFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__programaFound.tagName || '').toLowerCase(),
                text: String(__programaFound.textContent || '').trim()
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: ["action": actionName])
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: metadata)
                }

                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "action": actionName,
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref
                ]
                for (k, v) in metadata {
                    payload[k] = v
                }
                if let tag = dict["tag"] as? String {
                    payload["tag"] = tag
                }
                if let text = dict["text"] as? String {
                    payload["text"] = text
                }
                return .ok(payload)
            }
        }
    }

    func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false
        let roleLiteral = v2JSONLiteral(role)
        let nameLiteral = name.map(v2JSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.role",
            finderBody: finder,
            metadata: [
                "role": role,
                "name": v2OrNull(name),
                "exact": exact
            ]
        )
    }

    func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let textLiteral = v2JSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": text, "exact": exact]
        )
    }

    func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let labelLiteral = v2JSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": label, "exact": exact]
        )
    }

    func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let placeholderLiteral = v2JSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": placeholder, "exact": exact]
        )
    }

    func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let altLiteral = v2JSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": alt, "exact": exact]
        )
    }

    func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let titleLiteral = v2JSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": title, "exact": exact]
        )
    }

    func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = v2JSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": testId]
        )
    }

    func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const nth = idx + 1;
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${nth})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector, "index": index])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "index": v2OrNull(dict["index"]),
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    switch v2BrowserApplyFrameSelector(
                        selector,
                        surfaceId: surfaceId,
                        source: .frameSelect
                    ) {
                    case .applied:
                        break
                    case .rejected(let limit):
                        return .err(
                            code: "invalid_params",
                            message: "Frame selector exceeds \(limit) bytes",
                            data: ["selector": selector]
                        )
                    }
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserEnsureDialogHooks(browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            v2BrowserEnsureDialogHooks(browserPanel: browserPanel)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__programaDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__programaDialogDefaults = window.__programaDialogDefaults || { confirm: false, prompt: null };
                window.__programaDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__programaDialogDefaults = window.__programaDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__programaDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__programaDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": []])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
            let timeout = Double(timeoutMs) / 1000.0
            let path = v2String(params, "path")

            if let path {
                let fm = FileManager.default
                let pathIsReady = {
                    guard fm.fileExists(atPath: path),
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? NSNumber else {
                        return false
                    }
                    return size.intValue > 0
                }
                if pathIsReady() {
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "path": path,
                        "downloaded": true
                    ])
                }

                let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
                let fd = open(watchedPath, O_EVTONLY)
                guard fd >= 0 else {
                    return .err(code: "internal_error", message: "Failed to watch download path", data: ["path": path])
                }

                let ready = v2AwaitCallback(timeout: timeout) { finish in
                    var source: DispatchSourceFileSystemObject?
                    var timeoutWorkItem: DispatchWorkItem?
                    var finished = false
                    let finishOnce: (Bool) -> Void = { value in
                        guard !finished else { return }
                        finished = true
                        timeoutWorkItem?.cancel()
                        source?.cancel()
                        finish(value)
                    }
                    source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .extend, .attrib, .link, .rename],
                        queue: .main
                    )
                    source?.setEventHandler {
                        if pathIsReady() {
                            finishOnce(true)
                        }
                    }
                    source?.setCancelHandler {
                        // Close here, not in an outer `defer`: two asyncAfter timeouts (this
                        // one and v2AwaitCallback's) can race to tear this down, and closing
                        // in a defer scoped to the whole function could run while the source
                        // is still uncancelled.
                        Darwin.close(fd)
                        source = nil
                    }
                    source?.resume()
                    timeoutWorkItem = DispatchWorkItem {
                        finishOnce(pathIsReady())
                    }
                    if let timeoutWorkItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                    }
                    if pathIsReady() {
                        finishOnce(true)
                    }
                } ?? false
                guard ready else {
                    return .err(code: "timeout", message: "Timed out waiting for download file", data: ["path": path, "timeout_ms": timeoutMs])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "path": path,
                    "downloaded": true
                ])
            }

            if let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first {
                var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                remaining.removeFirst()
                v2BrowserDownloadEventsBySurface[surfaceId] = remaining
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "download": first
                ])
            }

            var waitState: BrowserDownloadWaitState?
            let downloadEvent = v2AwaitCallback(timeout: timeout) { finish in
                let state = BrowserDownloadWaitState(surfaceId: surfaceId, finish: finish)
                waitState = state
                let observer = NotificationCenter.default.addObserver(
                    forName: .browserDownloadEventDidArrive,
                    object: nil,
                    queue: .main
                ) { [state] note in
                    MainActor.assumeIsolated {
                        state.receive(note)
                    }
                }
                state.install(observer)
            }
            waitState?.cancel()
            guard let downloadEvent else {
                return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "download": downloadEvent
            ])
        }
    }

    func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "http_only": cookie.isHTTPOnly,
            "same_site": cookie.sameSitePolicy?.rawValue ?? NSNull(),
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = v2UUID(params, "pane_id")
                ?? v2UUID(params, "target_pane_id")
                ?? (v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: true) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        return result
    }

    func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = ws.closePanel(targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        return result
    }

    func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__programaConsoleLog) ? window.__programaConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__programaConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__programaErrorLog) ? window.__programaErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__programaErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
        return v2BrowserSelectorAction(params: params, actionName: "highlight") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const prev = el.style.outline;
              const prevOffset = el.style.outlineOffset;
              el.style.outline = '3px solid #ff9f0a';
              el.style.outlineOffset = '2px';
              setTimeout(() => {
                el.style.outline = prev;
                el.style.outlineOffset = prevOffset;
              }, 1200);
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let storageScript = """
            (() => {
              const readStorage = (st) => {
                const out = {};
                if (!st) return out;
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return out;
              };
              return {
                local: readStorage(window.localStorage),
                session: readStorage(window.sessionStorage)
              };
            })()
            """

            let storageValue: Any
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)

            let data: Data
            switch V2BrowserStateRestorer.encodeDocument(
                url: browserPanel.currentURL,
                cookies: cookies,
                storage: storageValue,
                frameSelector: v2BrowserFrameSelectorBySurface[surfaceId]
            ) {
            case .success(let encoded):
                data = encoded
            case .failure(let failure):
                return v2BrowserStateRestoreFailureResult(failure, path: path)
            }

            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "cookies": cookies.count
            ])
        }
    }

    func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        let preparedState: V2BrowserStateRestorer.PreparedState
        switch V2BrowserStateRestorer.prepare(fileURL: URL(fileURLWithPath: path)) {
        case .success(let state):
            preparedState = state
        case .failure(let failure):
            return v2BrowserStateRestoreFailureResult(failure, path: path)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let restoreLease = browserPanel.beginBrowserStateRestore() else {
                let dataStoreID = ObjectIdentifier(browserPanel.webView.configuration.websiteDataStore)
                let leaseState = V2BrowserStateRestoreLeaseCoordinator.shared.state(
                    dataStoreID: dataStoreID
                )
                let message = leaseState == .taintedByUndrainedMutationCallbacks
                    ? "Browser data store is waiting for an issued WebKit mutation callback to drain"
                    : "Another browser state restore is already active on this data store"
                return .err(
                    code: "busy",
                    message: message,
                    data: [
                        "surface_id": surfaceId.uuidString,
                        "path": path,
                        "busy_reason": leaseState.rawValue,
                    ]
                )
            }
            defer { browserPanel.endBrowserStateRestore(restoreLease) }

            let restoreWebView = browserPanel.webView
            let restoreWebViewInstanceID = browserPanel.webViewInstanceID
            let leaseCoordinator = V2BrowserStateRestoreLeaseCoordinator.shared
            let operations = V2BrowserStateRestoreOperations(
                installCookies: { cookies, _ in
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID else {
                        return .unavailable(message: "Browser surface changed before cookies were installed")
                    }
                    guard !cookies.isEmpty else { return .succeeded }

                    let cookieStore = restoreWebView.configuration.websiteDataStore.httpCookieStore
                    guard leaseCoordinator.beginPendingMutation(restoreLease) else {
                        return .unavailable(message: "Browser state restore was invalidated before cookies were installed")
                    }
                    let completed: Void? = self.v2AwaitCallback(timeout: 10.0) { finish in
                        let group = DispatchGroup()
                        for cookie in cookies {
                            group.enter()
                            cookieStore.setCookie(cookie) {
                                group.leave()
                            }
                        }
                        group.notify(queue: .main) {
                            leaseCoordinator.endPendingMutation(restoreLease)
                            finish(())
                        }
                    }
                    guard completed != nil else { return .timedOut }
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID else {
                        return .unavailable(message: "Browser surface changed while cookies were being installed")
                    }
                    return .succeeded
                },
                navigateAndWait: { targetURL in
                    let result: V2BrowserStateNavigationOutcome? = self.v2AwaitCallback(timeout: 20.0) { finish in
                        let startOutcome = browserPanel.startBrowserStateRestoreNavigation(to: targetURL) { outcome in
                            switch outcome {
                            case .finished(let committed, let finished):
                                finish(
                                    .finished(
                                        committed: V2BrowserStateNavigationMilestone(
                                            navigationID: committed.navigationID,
                                            url: committed.url,
                                            executionURL: committed.executionURL
                                        ),
                                        finished: V2BrowserStateNavigationMilestone(
                                            navigationID: finished.navigationID,
                                            url: finished.url,
                                            executionURL: finished.executionURL
                                        )
                                    )
                                )
                            case .cancelled:
                                finish(.cancelled)
                            case .permissionDenied:
                                finish(.permissionDenied)
                            case .unavailable:
                                finish(.unavailable)
                            case .failed(let message):
                                finish(.failed(message: message))
                            }
                        }
                        switch startOutcome {
                        case .started:
                            break
                        case .permissionDenied:
                            finish(.permissionDenied)
                        case .unavailable:
                            finish(.unavailable)
                        case .busy:
                            finish(.busy)
                        }
                    }
                    guard let result else {
                        return .timedOut
                    }
                    return result
                },
                applyStorage: { storage in
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID,
                          let actualURL = restoreWebView.url else {
                        return .unavailable(message: "Browser surface changed before storage was applied")
                    }
                    guard V2BrowserStateRestorer.originString(for: actualURL) == storage.executionOrigin else {
                        return .originMismatch(message: "Browser origin changed before storage was applied")
                    }

                    let storageLiteral = self.v2JSONLiteral([
                        "local": storage.local,
                        "session": storage.session,
                    ])
                    let originLiteral = self.v2JSONLiteral(storage.executionOrigin)
                    let script = """
                    return (() => {
                      const expectedOrigin = \(originLiteral);
                      const payload = \(storageLiteral);
                      try {
                        const actualOrigin = String(location.origin || '');
                        if (actualOrigin !== expectedOrigin) {
                          return { ok: false, kind: 'origin_mismatch', actual_origin: actualOrigin };
                        }
                        const apply = (target, entries) => {
                          target.clear();
                          for (const [key, value] of Object.entries(entries)) {
                            target.setItem(key, value);
                          }
                        };
                        apply(window.localStorage, payload.local);
                        apply(window.sessionStorage, payload.session);
                        return { ok: true };
                      } catch (error) {
                        return {
                          ok: false,
                          kind: 'storage_error',
                          message: String(error && error.message ? error.message : error)
                        };
                      }
                    })();
                    """
                    guard leaseCoordinator.beginPendingMutation(restoreLease) else {
                        return .unavailable(message: "Browser state restore was invalidated before storage was applied")
                    }
                    switch self.v2RunJavaScript(
                        restoreWebView,
                        script: script,
                        timeout: 10.0,
                        preferAsync: true,
                        contentWorld: .defaultClient,
                        webKitCompletionDidDrain: {
                            leaseCoordinator.endPendingMutation(restoreLease)
                        }
                    ) {
                    case .failure(let message):
                        if message == "Timed out waiting for JavaScript result" {
                            return .timedOut
                        }
                        return .failed(message: message)
                    case .success(let value):
                        guard let response = value as? [String: Any],
                              let ok = response["ok"] as? Bool else {
                            return .failed(message: "Invalid browser storage result")
                        }
                        if ok { return .succeeded }
                        if response["kind"] as? String == "origin_mismatch" {
                            return .originMismatch(message: "Browser origin changed while storage was being applied")
                        }
                        return .failed(
                            message: (response["message"] as? String) ?? "Browser storage mutation failed"
                        )
                    }
                },
                applyFrameSelector: { frameSelector in
                    switch self.v2BrowserApplyFrameSelector(
                        frameSelector,
                        surfaceId: surfaceId,
                        source: .stateLoad
                    ) {
                    case .applied:
                        return .succeeded
                    case .rejected(let limit):
                        return .failed(message: "Frame selector exceeds \(limit) bytes")
                    }
                },
                leaseIsValid: {
                    browserPanel.isBrowserStateRestoreLeaseValid(restoreLease)
                        && browserPanel.webView === restoreWebView
                        && browserPanel.webViewInstanceID == restoreWebViewInstanceID
                },
                cancelNavigation: {
                    browserPanel.cancelBrowserStateRestoreNavigationWait()
                }
            )

            switch V2BrowserStateRestorer.execute(preparedState, using: operations) {
            case .failure(let failure):
                return v2BrowserStateRestoreFailureResult(failure, path: path)
            case .success:
                break
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "loaded": true,
                "url": preparedState.targetURL.absoluteString,
                "cookies": preparedState.cookies.count,
            ])
        }
    }

    private func v2BrowserStateRestoreFailureResult(
        _ failure: V2BrowserStateRestoreFailure,
        path: String
    ) -> V2CallResult {
        let code: String
        switch failure.code {
        case .documentReadFailed:
            code = "not_found"
        case .documentNotRegular, .documentTooLarge, .malformedDocument, .unsupportedSchemaVersion,
             .invalidURL, .invalidCookie, .duplicateCookie,
             .cookieLimitExceeded, .storageEntryLimitExceeded, .storageKeyTooLarge,
             .storageValueTooLarge, .frameSelectorTooLarge:
            code = "invalid_params"
        case .navigationPermissionDenied:
            code = "permission_denied"
        case .navigationUnavailable, .surfaceUnavailable, .cookieInstallFailed, .restoreInvalidated:
            code = "unavailable"
        case .navigationBusy:
            code = "busy"
        case .navigationTimedOut, .cookieInstallTimedOut, .storageApplyTimedOut,
             .frameSelectorApplyTimedOut:
            code = "timeout"
        case .navigationCancelled:
            code = "cancelled"
        case .navigationFailed, .navigationMismatch:
            code = "navigation_failed"
        case .originMismatch:
            code = "origin_mismatch"
        case .storageApplyFailed:
            code = "storage_apply_failed"
        case .frameSelectorApplyFailed:
            code = "internal_error"
        }

        var data: [String: Any] = ["path": path]
        if failure.cookiesMayHaveBeenMutated {
            data["partial_cookie_mutation"] = true
            data["cookies_attempted"] = failure.cookieCount
        }
        if failure.storageMayHaveBeenMutated {
            data["partial_storage_mutation"] = true
        }
        return .err(code: code, message: failure.message, data: data)
    }

    func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "scripts": scripts.count
            ])
        }
    }

    func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: source, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "styles": styles.count
            ])
        }
    }

    func v2BrowserViewportSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.viewport.set", details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP")
    }

    func v2BrowserGeolocationSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.geolocation.set", details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP")
    }

    func v2BrowserOfflineSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.offline.set", details: "WKWebView does not expose reliable per-tab offline emulation")
    }

    func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }

}
