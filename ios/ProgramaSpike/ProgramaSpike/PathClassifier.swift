import Darwin
import Foundation
import IrohLib

/// Duplicated (not shared) from `tools/mobile-spike/Sources/iroh-spike`; see
/// that copy's doc comment for why this reimplements — rather than reuses —
/// `CmuxIrohTransport`'s internal path classification.
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

    static func waitForSelectedPath(
        connection: Connection,
        timeout: Duration
    ) async -> ObservedPath {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let classified = classify(connection.paths())
            if case .unavailable = classified {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            return classified
        }
        return classify(connection.paths())
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
