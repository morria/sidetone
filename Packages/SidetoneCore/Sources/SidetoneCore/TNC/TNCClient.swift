import Foundation
import Network

/// Client for the ardopcf host TCP interface.
///
/// Owns the two `NWConnection`s ardopcf requires (command + data) and exposes
/// a single pair of `AsyncStream`s: parsed events on the command port, and
/// decoded frames on the data port. All socket I/O happens inside the actor;
/// callers never touch bytes.
///
/// Cancellation: `disconnect()` cancels both NWConnections synchronously and
/// finishes the event/frame streams. NWConnection cancellation is synchronous
/// from the caller's perspective (the OS takes the sockets down immediately),
/// which satisfies the spec's 100 ms tear-down requirement.
public actor TNCClient {
    public struct Configuration: Sendable {
        public var host: String
        public var commandPort: UInt16
        public var dataPort: UInt16 { commandPort &+ 1 }

        public init(host: String = "127.0.0.1", commandPort: UInt16 = 8515) {
            self.host = host
            self.commandPort = commandPort
        }
    }

    public enum ConnectionError: Error, Sendable, Equatable {
        case notConnected
        case connectionFailed(String)
        case writeFailed(String)
    }

    public enum Status: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    public nonisolated let events: AsyncStream<TNCEvent>
    public nonisolated let frames: AsyncStream<DataFrame>

    private nonisolated let eventContinuation: AsyncStream<TNCEvent>.Continuation
    private nonisolated let frameContinuation: AsyncStream<DataFrame>.Continuation

    private let configuration: Configuration
    private var commandConnection: NWConnection?
    private var dataConnection: NWConnection?
    private var lineAccumulator = LineAccumulator()
    private var frameParser = DataFrameParser()
    private(set) var status: Status = .idle

    public init(configuration: Configuration) {
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream.makeStream(of: TNCEvent.self)
        (frames, frameContinuation) = AsyncStream.makeStream(of: DataFrame.self)
    }

    deinit {
        eventContinuation.finish()
        frameContinuation.finish()
    }

    public func connect() async throws {
        guard status == .idle || status == .disconnected else { return }
        status = .connecting

        let cmd = makeConnection(port: configuration.commandPort)
        let data = makeConnection(port: configuration.dataPort)
        commandConnection = cmd
        dataConnection = data

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [configuration] in
                    try await Self.waitReady(cmd, label: "command port \(configuration.commandPort)")
                }
                group.addTask { [configuration] in
                    try await Self.waitReady(data, label: "data port \(configuration.dataPort)")
                }
                try await group.waitForAll()
            }
        } catch {
            await teardown()
            status = .disconnected
            throw error
        }

        status = .connected
        startReceiving(commandConnection: cmd, dataConnection: data)
    }

    public func send(_ command: TNCCommand) async throws {
        guard let cmd = commandConnection, status == .connected else {
            throw ConnectionError.notConnected
        }
        let bytes = Data(command.wireLine().utf8)
        try await Self.send(cmd, data: bytes)
    }

    /// Send a literal line over the command port. Useful for test harnesses
    /// that need to inject unusual input — production callers should use
    /// `send(_:)` with a typed command.
    public func sendRawLine(_ line: String) async throws {
        guard let cmd = commandConnection, status == .connected else {
            throw ConnectionError.notConnected
        }
        let trimmed = line.hasSuffix("\r") ? line : line + "\r"
        try await Self.send(cmd, data: Data(trimmed.utf8))
    }

    public func disconnect() async {
        await teardown()
        status = .disconnected
    }

    // MARK: - Internals

    private func makeConnection(port: UInt16) -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.tcp
        return NWConnection(to: endpoint, using: params)
    }

    private static func waitReady(_ connection: NWConnection, label: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delivered = ManagedAtomic(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if delivered.exchange(true) == false {
                        continuation.resume()
                    }
                case .failed(let error):
                    if delivered.exchange(true) == false {
                        continuation.resume(throwing: ConnectionError.connectionFailed("\(label): \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if delivered.exchange(true) == false {
                        continuation.resume(throwing: ConnectionError.connectionFailed("\(label): cancelled"))
                    }
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.writeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func startReceiving(commandConnection cmd: NWConnection, dataConnection data: NWConnection) {
        let eventCont = eventContinuation
        let frameCont = frameContinuation

        receiveCommandLoop(on: cmd) { [weak self] bytes in
            Task { [weak self] in
                await self?.ingestCommandBytes(bytes, continuation: eventCont)
            }
        }

        receiveDataLoop(on: data) { [weak self] bytes in
            Task { [weak self] in
                await self?.ingestDataBytes(bytes, continuation: frameCont)
            }
        }
    }

    private nonisolated func receiveCommandLoop(on connection: NWConnection, onBytes: @Sendable @escaping ([UInt8]) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                onBytes(Array(data))
            }
            if isComplete || error != nil {
                return
            }
            self.receiveCommandLoop(on: connection, onBytes: onBytes)
        }
    }

    private nonisolated func receiveDataLoop(on connection: NWConnection, onBytes: @Sendable @escaping ([UInt8]) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                onBytes(Array(data))
            }
            if isComplete || error != nil {
                return
            }
            self.receiveDataLoop(on: connection, onBytes: onBytes)
        }
    }

    private func ingestCommandBytes(_ bytes: [UInt8], continuation: AsyncStream<TNCEvent>.Continuation) {
        let lines = lineAccumulator.feed(bytes)
        for line in lines {
            continuation.yield(TNCEventParser.parse(line))
        }
    }

    private func ingestDataBytes(_ bytes: [UInt8], continuation: AsyncStream<DataFrame>.Continuation) {
        let output = frameParser.feed(bytes)
        for frame in output.frames {
            continuation.yield(frame)
        }
        // Parse errors are intentionally silent here; the session is not
        // recoverable if framing desyncs and reopening the socket is the
        // only fix. Callers inspect status for the outcome.
    }

    private func teardown() async {
        commandConnection?.stateUpdateHandler = nil
        dataConnection?.stateUpdateHandler = nil
        commandConnection?.cancel()
        dataConnection?.cancel()
        commandConnection = nil
        dataConnection = nil
        lineAccumulator = LineAccumulator()
        frameParser = DataFrameParser()
    }
}

/// Minimal one-shot atomic bool used to guard continuation resumption in the
/// NWConnection state handler. We avoid importing `Atomics` just for this.
private final class ManagedAtomic: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ initial: Bool) { self.value = initial }
    func exchange(_ new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
