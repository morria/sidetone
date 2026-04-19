import Foundation
import Network

/// Minimal scriptable rigctld mock for exercising `RigctldClient`. Accepts
/// one client connection, reads LF-terminated commands, and replies per a
/// caller-supplied `respond` closure. The closure returns an array of lines
/// (already sans LF); the server adds LFs and sends.
public actor MockRigctldServer {
    public typealias Responder = @Sendable (String) -> [String]

    private var listener: NWListener?
    private var connection: NWConnection?
    private let responder: Responder
    private var buffer: [UInt8] = []

    public init(responder: @escaping Responder) {
        self.responder = responder
    }

    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        return try await Self.waitForPort(listener)
    }

    public func stop() async {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection)
    }

    private nonisolated func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { [weak self] in
                    await self?.ingest(Array(data), on: connection)
                }
            }
            if isComplete || error != nil { return }
            self?.receiveLoop(connection)
        }
    }

    private func ingest(_ bytes: [UInt8], on connection: NWConnection) async {
        buffer.append(contentsOf: bytes)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineBytes = buffer[..<nl]
            buffer.removeSubrange(...nl)
            guard let line = String(bytes: lineBytes, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\t "))
            let reply = responder(trimmed)
            var payload = Data()
            for line in reply {
                payload.append(contentsOf: line.utf8)
                payload.append(0x0a)
            }
            await Self.send(connection, data: payload)
        }
    }

    private static func waitForPort(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = MockRigOnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.trip() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: CocoaError(.featureUnsupported))
                    }
                case .failed(let err):
                    guard once.trip() else { return }
                    continuation.resume(throwing: err)
                case .cancelled:
                    guard once.trip() else { return }
                    continuation.resume(throwing: CocoaError(.featureUnsupported))
                default:
                    break
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

private final class MockRigOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}
