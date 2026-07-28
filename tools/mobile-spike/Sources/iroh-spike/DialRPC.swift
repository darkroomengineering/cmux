import Foundation
import IrohLib

/// Test/debug helper for the bridge: dials a running `bridge`, optionally
/// pairs with a token, sends one JSON-RPC line, and prints the reply. Exists
/// so the admission + allow-list + relay path is exercisable from a shell
/// without the iOS app (see the M1 bridge verification plan).
func runDialRPC(ticket ticketString: String, token: String?, requestJSON: String) async throws {
    let ticket: EndpointTicket
    do {
        ticket = try EndpointTicket.fromString(str: ticketString)
    } catch {
        throw SpikeError(message: "could not parse pairing payload: \(error)")
    }
    let targetAddress = ticket.endpointAddr()

    let endpoint = try await bindEndpoint()

    print("Dialing \(targetAddress.id())...")
    let connection = try await endpoint.connect(addr: targetAddress, alpn: bridgeALPN)
    try connection.setMaxConcurrentBiStreams(count: 1)
    try connection.setMaxConcurrentUniStreams(count: 0)
    try await connection.authorizeNatTraversal()

    let stream = try await connection.openBi()
    let sendStream = stream.send()
    let reader = StreamLineReader(stream: stream.recv())

    if let token {
        let pairingLine = Data(#"{"pair":"\#(token)"}"#.utf8) + Data("\n".utf8)
        try await sendStream.writeAll(buf: pairingLine)

        switch try await withTimeout(seconds: 10, operation: { try await reader.nextLine() }) {
        case let .value(line):
            guard let line else {
                throw SpikeError(message: "no pairing reply from bridge (connection closed)")
            }
            print("Pairing reply: \(describe(line))")
        case .timedOut:
            throw SpikeError(message: "timed out waiting for pairing reply from bridge")
        }
    }

    let requestLine = Data(requestJSON.utf8) + Data("\n".utf8)
    try await sendStream.writeAll(buf: requestLine)

    // Unsolicited event frames ("event" key, no "id") share this stream and can
    // arrive before the reply -- the bridge greets every admitted peer with
    // `bridge_hello` immediately. Skip them while waiting for the response, the
    // same way the iOS client routes by frame shape rather than arrival order.
    var responseLine: Data?
    var streamClosed = false
    while responseLine == nil, !streamClosed {
        switch try await withTimeout(seconds: 10, operation: { try await reader.nextLine() }) {
        case let .value(line):
            guard let line else {
                print("Response: <connection closed without a reply>")
                streamClosed = true
                continue
            }
            if isEventFrame(line) {
                print("Event: \(describe(line))")
                continue
            }
            responseLine = line
        case .timedOut:
            throw SpikeError(message: "timed out waiting for response from bridge")
        }
    }
    if let responseLine {
        print("Response: \(describe(responseLine))")
    }

    // With PROGRAMA_SPIKE_FOLLOW=<seconds>, keep reading after the reply so
    // unsolicited event frames (which arrive with an "event" key and no "id",
    // pushed by the server well after a subscribe is answered) can be observed.
    // Without this the process exits within milliseconds and event delivery --
    // the single capability the mobile product is built on -- is untestable.
    if let raw = ProcessInfo.processInfo.environment["PROGRAMA_SPIKE_FOLLOW"],
       let seconds = Double(raw), seconds > 0 {
        // Read exactly one further frame, then stop. `withTimeout` races a
        // sleep against the read, but the underlying iroh read is an FFI call
        // that does not observe Task cancellation — so a timed-out read stays
        // parked forever and looping here hangs the process even though the
        // frame we wanted already arrived. One bounded read is enough to prove
        // unsolicited frames reach the client, which is all this flag is for.
        print("Following for up to \(seconds)s (one frame)...")
        switch try await withTimeout(
            seconds: seconds,
            operation: { try await reader.nextLine() }
        ) {
        case let .value(line):
            if let line {
                print("Follow frame: \(describe(line))")
            } else {
                print("Follow: <connection closed before any event>")
            }
        case .timedOut:
            print("Follow: <no event frame within \(seconds)s>")
        }
    }

    try? connection.close(errorCode: 0, reason: Data("dial_rpc_complete".utf8))
    try? await endpoint.close()
}

private func describe(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "<\(data.count) binary bytes>"
}

private enum TimedResult<T: Sendable>: Sendable {
    case value(T)
    case timedOut
}

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> TimedResult<T> {
    try await withThrowingTaskGroup(of: TimedResult<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .timedOut
        }
        guard let first = try await group.next() else {
            group.cancelAll()
            throw SpikeError(message: "timeout race produced no result")
        }
        group.cancelAll()
        return first
    }
}


/// True for unsolicited server-pushed frames: they carry an "event" key and no
/// "id", which is how both this helper and the iOS client tell them apart from
/// replies without depending on arrival order.
func isEventFrame(_ line: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        return false
    }
    return object["event"] != nil && object["id"] == nil
}
