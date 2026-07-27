import Darwin
import Foundation
import IrohLib

/// The observed transport path for a connection, mirroring the four-way
/// split the mobile companion app needs to display: direct, private-network
/// (LAN-local, still peer-to-peer), relayed, or not yet known.
///
/// This is a standalone reimplementation of the same classification idea as
/// `CmuxIrohTransport`'s internal `CmxIrohObservedConnectionPath` /
/// `CmxIrohIPAddressScope` (both `internal`, unusable outside that module).
/// It is intentionally simpler: no managed/custom relay policy lookup, just
/// the four cases this spike needs.
enum ObservedPath: CustomStringConvertible {
    case direct
    case privateNetwork
    case relay(url: String)
    case unavailable

    var description: String {
        switch self {
        case .direct: "direct"
        case .privateNetwork: "private network"
        case let .relay(url): "relay (\(url))"
        case .unavailable: "unavailable"
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

    /// Polls `connection.paths()` for the *settled* path, not the first one.
    ///
    /// iroh always establishes over a relay first and only upgrades to a direct
    /// path once hole-punching succeeds, which takes a few seconds after
    /// `authorizeNatTraversal()`. Returning the first selected path therefore
    /// reports `relay` essentially always — including for two peers on the same
    /// machine — which would make this spike's central measurement meaningless.
    ///
    /// So: return as soon as a peer-to-peer path is selected, and only fall back
    /// to reporting a relay if the whole window elapses without an upgrade.
    static func waitForSelectedPath(
        connection: Connection,
        timeout: Duration
    ) async -> ObservedPath {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastRelay: ObservedPath?

        while ContinuousClock.now < deadline {
            let classified = classify(connection.paths())
            switch classified {
            case .direct, .privateNetwork:
                return classified
            case .relay:
                lastRelay = classified
            case .unavailable:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return lastRelay ?? classify(connection.paths())
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
