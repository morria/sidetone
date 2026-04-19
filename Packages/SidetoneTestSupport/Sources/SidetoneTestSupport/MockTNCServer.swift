import Foundation
import Network
import SidetoneCore

/// A scriptable mock of `ardopcf` for driving `TNCClient` through every
/// state. Opens two TCP listeners on the local loopback at command/data
/// ports, accepts exactly one client connection on each, and replays or
/// generates host-protocol lines and data frames on demand.
///
/// This is deliberately a real TCP server rather than a protocol-level
/// fake: the whole point is to exercise the socket-buffering and split-read
/// paths the real client will hit in production. Fixtures captured from a
/// real ardopcf can be replayed byte-for-byte.
public actor MockTNCServer {
    public struct Ports: Sendable {
        public let command: UInt16
        public let data: UInt16
    }

    public enum ServerError: Error, Sendable, Equatable {
        case notStarted
        case noClient
    }

    private var commandListener: NWListener?
    private var dataListener: NWListener?
    private var commandConnection: NWConnection?
    private var dataConnection: NWConnection?
    private var commandReady: CheckedContinuation<Void, Never>?
    private var dataReady: CheckedContinuation<Void, Never>?
    private var receivedLinesContinuation: AsyncStream<String>.Continuation?
    private var receivedCommandBuffer = LineAccumulator()

    public nonisolated let receivedLines: AsyncStream<String>
    private nonisolated let _receivedLinesCont: AsyncStream<String>.Continuation

    public init() {
        (receivedLines, _receivedLinesCont) = AsyncStream.makeStream(of: String.self)
    }

    /// Start listening on two ephemeral ports. Returns the port numbers so
    /// tests can configure a `TNCClient` to connect.
    public func start() async throws -> Ports {
        let cmd = try NWListener(using: .tcp)
        let data = try NWListener(using: .tcp)
        commandListener = cmd
        dataListener = data

        cmd.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptCommand(connection) }
        }
        data.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptData(connection) }
        }

        cmd.start(queue: .global(qos: .userInitiated))
        data.start(queue: .global(qos: .userInitiated))

        // NWListener assigns a real port asynchronously after .ready.
        let cmdPort = try await Self.waitForPort(cmd)
        let dataPort = try await Self.waitForPort(data)

        return Ports(command: cmdPort, data: dataPort)
    }

    public func stop() async {
        commandConnection?.cancel()
        dataConnection?.cancel()
        commandListener?.cancel()
        dataListener?.cancel()
        commandConnection = nil
        dataConnection = nil
        commandListener = nil
        dataListener = nil
        _receivedLinesCont.finish()
    }

    /// Wait until the client has connected to both ports.
    public func awaitClient() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.commandReady = c
            if self.commandConnection != nil {
                self.commandReady = nil
                c.resume()
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.dataReady = c
            if self.dataConnection != nil {
                self.dataReady = nil
                c.resume()
            }
        }
    }

    /// Send an unsolicited line over the command port. The trailing `\r` is
    /// added if not present.
    public func emit(_ line: String) async throws {
        guard let conn = commandConnection else { throw ServerError.noClient }
        let withCR = line.hasSuffix("\r") ? line : line + "\r"
        try await Self.send(conn, data: Data(withCR.utf8))
    }

    /// Send a binary data frame over the data port using the canonical
    /// ardopcf framing (2-byte BE length including 3-byte tag, then tag,
    /// then payload).
    public func emitFrame(tag: String, payload: Data) async throws {
        guard let conn = dataConnection else { throw ServerError.noClient }
        let bytes = DataFrameEncoder.encode(tag: tag, payload: payload)
        try await Self.send(conn, data: bytes)
    }

    /// Send already-encoded bytes to the data port. Primarily for fuzz tests
    /// that need to exercise split reads and malformed frames.
    public func emitRawDataBytes(_ bytes: Data) async throws {
        guard let conn = dataConnection else { throw ServerError.noClient }
        try await Self.send(conn, data: bytes)
    }

    // MARK: - Internals

    private func acceptCommand(_ connection: NWConnection) {
        commandConnection = connection
        connection.start(queue: .global(qos: .userInitiated))
        receiveCommandLoop(connection)
        if let c = commandReady { commandReady = nil; c.resume() }
    }

    private func acceptData(_ connection: NWConnection) {
        dataConnection = connection
        connection.start(queue: .global(qos: .userInitiated))
        if let c = dataReady { dataReady = nil; c.resume() }
    }

    private nonisolated func receiveCommandLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                Task { [weak self] in
                    await self?.ingestClientBytes(Array(data))
                }
            }
            if isComplete || error != nil { return }
            self?.receiveCommandLoop(connection)
        }
    }

    private func ingestClientBytes(_ bytes: [UInt8]) {
        let lines = receivedCommandBuffer.feed(bytes)
        for line in lines {
            _receivedLinesCont.yield(line)
        }
    }

    private static func waitForPort(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let guard_ = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard guard_.trip() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: ServerError.notStarted)
                    }
                case .failed(let err):
                    guard guard_.trip() else { return }
                    continuation.resume(throwing: err)
                case .cancelled:
                    guard guard_.trip() else { return }
                    continuation.resume(throwing: ServerError.notStarted)
                default:
                    break
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// One-shot guard: `trip()` returns true exactly once across all callers.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}
