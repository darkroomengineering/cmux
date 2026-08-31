import Darwin
import Foundation
import IrohLib

/// The mobile app's user-facing classification of iroh's selected path.
enum ObservedPath: CustomStringConvertible, Equatable, Sendable {
    case direct
    case privateNetwork
    case relay(url: String)
    case unavailable

    var description: String {
        switch self {
        case .direct: String(localized: "connection.path.direct", defaultValue: "direct")
        case .privateNetwork: String(localized: "connection.path.privateNetwork", defaultValue: "private network")
        case let .relay(url):
            String.localizedStringWithFormat(
                String(localized: "connection.path.relay", defaultValue: "relay (%@)"),
                url
            )
        case .unavailable: String(localized: "connection.path.unavailable", defaultValue: "unavailable")
        }
    }
}

enum PathClassifier {
    static func classify(_ snapshots: [PathSnapshot]) -> ObservedPath {
        guard let selected = snapshots.first(where: \.isSelected) else {
            return .unavailable
        }
        if selected.isRelay {
            return .relay(url: selected.remoteAddr)
        }
        if selected.isIp {
            return isPrivateAddress(selected.remoteAddr) ? .privateNetwork : .direct
        }
        return .unavailable
    }

    static func waitForSelectedPath(
        connection: Connection,
        timeout: Duration
    ) async -> ObservedPath {
        await waitForSelectedPath(
            timeout: timeout,
            now: { ContinuousClock.now },
            selectedPath: { classify(connection.paths()) },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    static func waitForSelectedPath(
        timeout: Duration,
        now: () -> ContinuousClock.Instant,
        selectedPath: () -> ObservedPath,
        sleep: (Duration) async throws -> Void
    ) async -> ObservedPath {
        let deadline = now().advanced(by: timeout)
        var lastRelay: ObservedPath?
        var lastObserved = ObservedPath.unavailable

        while now() < deadline {
            guard !Task.isCancelled else { return lastRelay ?? lastObserved }
            let classified = selectedPath()
            lastObserved = classified
            switch classified {
            case .direct, .privateNetwork:
                return classified
            case .relay:
                lastRelay = classified
            case .unavailable:
                break
            }
            do {
                try await sleep(.milliseconds(100))
            } catch {
                // Task.sleep throws on cancellation. Returning the last useful observation
                // preserves this non-throwing connection-status contract without hot-spinning
                // until the original deadline.
                return lastRelay ?? lastObserved
            }
        }

        return lastRelay ?? selectedPath()
    }

    private static func isPrivateAddress(_ socketAddress: String) -> Bool {
        guard let host = host(from: socketAddress) else { return false }
        let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host

        var ipv4 = in_addr()
        if literal.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8(truncatingIfNeeded: address >> 24)
            let second = UInt8(truncatingIfNeeded: address >> 16)
            return first == 10
                || first == 127
                || (first == 100 && (64 ... 127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16 ... 31).contains(second))
                || (first == 192 && second == 168)
        }

        var ipv6 = in6_addr()
        if literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let isUniqueLocal = bytes[0] & 0xFE == 0xFC
            let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            return isUniqueLocal || isLinkLocal || isLoopback
        }

        return false
    }

    private static func host(from socketAddress: String) -> String? {
        if socketAddress.first == "[",
           let closingBracket = socketAddress.firstIndex(of: "]") {
            return String(
                socketAddress[socketAddress.index(after: socketAddress.startIndex) ..< closingBracket]
            )
        }
        let colonCount = socketAddress.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 1, let colon = socketAddress.lastIndex(of: ":") {
            return String(socketAddress[..<colon])
        }
        return colonCount > 1 ? socketAddress : nil
    }
}
