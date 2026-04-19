import Foundation
import Network

/// Minimal client for Hamlib's `rigctld` daemon TCP protocol (default
/// port 4532). Text-based, line-oriented, LF-terminated.
///
/// Queries return their value on its own line (e.g. `14250000`).
/// Set commands return `RPRT <code>` where 0 is success, negative is a
/// Hamlib error code. Failed queries also return `RPRT <negative>`.
///
/// We don't attempt to support the long-name (`\set_freq 14250000`)
/// aliases — the single-letter shorthands are sufficient for the subset
/// Sidetone drives (frequency, mode).
public actor RigctldClient {
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String = "127.0.0.1", port: UInt16 = 4532) {
            self.host = host
            self.port = port
        }
    }

    public enum ClientError: Error, Sendable, Equatable {
        case notConnected
        case connectionFailed(String)
        case writeFailed(String)
        case rigError(code: Int)
        case malformedResponse(String)
    }

    public struct Mode: Sendable, Equatable {
        public let name: String        // "USB", "LSB", "CW", "FM", etc.
        public let passbandHz: Int     // 0 means "unchanged / unknown"

        public init(name: String, passbandHz: Int) {
            self.name = name.uppercased()
            self.passbandHz = passbandHz
        }
    }

    private let configuration: Configuration
    private var connection: NWConnection?
    private var pendingReplies: [CheckedContinuation<[String], Error>] = []
    private var inFlightLinesExpected: [Int] = []
    private var lineAccumulator = LineAccumulator()
    private var bufferedLines: [String] = []

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = RigOnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.trip() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard once.trip() else { return }
                    continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    guard once.trip() else { return }
                    continuation.resume(throwing: ClientError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        startReceiveLoop(conn)
    }

    public func disconnect() async {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        // Drain any pending continuations as errors so callers don't hang.
        for cont in pendingReplies {
            cont.resume(throwing: ClientError.notConnected)
        }
        pendingReplies.removeAll()
        inFlightLinesExpected.removeAll()
        bufferedLines.removeAll()
        lineAccumulator = LineAccumulator()
    }

    // MARK: - Queries

    public func frequencyHz() async throws -> Int {
        let reply = try await sendAndAwait("f", expectedLines: 1)
        guard let hz = Int(reply.first ?? "") else {
            throw ClientError.malformedResponse(reply.joined(separator: "\n"))
        }
        return hz
    }

    public func mode() async throws -> Mode {
        let reply = try await sendAndAwait("m", expectedLines: 2)
        guard reply.count == 2, let passband = Int(reply[1]) else {
            throw ClientError.malformedResponse(reply.joined(separator: "\n"))
        }
        return Mode(name: reply[0], passbandHz: passband)
    }

    // MARK: - Sets

    public func setFrequency(_ hz: Int) async throws {
        _ = try await sendAndExpectRPRT("F \(hz)")
    }

    public func setMode(_ mode: Mode) async throws {
        _ = try await sendAndExpectRPRT("M \(mode.name) \(mode.passbandHz)")
    }

    // MARK: - Internals

    private func sendAndAwait(_ command: String, expectedLines: Int) async throws -> [String] {
        guard let conn = connection else { throw ClientError.notConnected }
        let wire = Data((command + "\n").utf8)
        try await Self.send(conn, data: wire)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            pendingReplies.append(continuation)
            inFlightLinesExpected.append(expectedLines)
            tryDeliver()
        }
    }

    private func sendAndExpectRPRT(_ command: String) async throws -> Int {
        let lines = try await sendAndAwait(command, expectedLines: 1)
        guard let line = lines.first else {
            throw ClientError.malformedResponse("")
        }
        // Expected format: "RPRT <code>"
        guard line.hasPrefix("RPRT ") else {
            throw ClientError.malformedResponse(line)
        }
        let code = Int(line.dropFirst("RPRT ".count)) ?? .min
        if code != 0 { throw ClientError.rigError(code: code) }
        return code
    }

    private func startReceiveLoop(_ conn: NWConnection) {
        receive(on: conn)
    }

    private nonisolated func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { [weak self] in
                    await self?.ingest(Array(data))
                }
            }
            if isComplete || error != nil { return }
            self?.receive(on: conn)
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        let lines = lineAccumulator.feed(bytes)
        bufferedLines.append(contentsOf: lines)
        tryDeliver()
    }

    /// Drain completed replies off the head of the buffer. Queries that
    /// expect multiple lines (e.g. mode returns two lines) wait for all
    /// expected lines before resuming the continuation.
    ///
    /// If a query returns `RPRT <negative>` before the expected number of
    /// value lines, we interpret it as a failed query and surface the
    /// error immediately rather than waiting for lines that will never
    /// arrive.
    private func tryDeliver() {
        while let expected = inFlightLinesExpected.first {
            // Short-circuit: the first line is a RPRT error — resume with
            // failure regardless of expected count.
            if let first = bufferedLines.first, first.hasPrefix("RPRT ") {
                let code = Int(first.dropFirst("RPRT ".count)) ?? .min
                bufferedLines.removeFirst()
                let cont = pendingReplies.removeFirst()
                inFlightLinesExpected.removeFirst()
                if code == 0 {
                    // SET success — give the caller `[RPRT 0]` back.
                    cont.resume(returning: [first])
                } else {
                    cont.resume(throwing: ClientError.rigError(code: code))
                }
                continue
            }

            guard bufferedLines.count >= expected else { return }
            let chunk = Array(bufferedLines.prefix(expected))
            bufferedLines.removeFirst(expected)
            let cont = pendingReplies.removeFirst()
            inFlightLinesExpected.removeFirst()
            cont.resume(returning: chunk)
        }
    }

    private static func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ClientError.writeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

private final class RigOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}
