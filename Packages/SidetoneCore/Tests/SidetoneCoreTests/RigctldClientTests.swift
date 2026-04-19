import Foundation
import Testing
@testable import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    @Suite("RigctldClient ↔ MockRigctldServer")
    struct RigctldSuite {
        @Test("get frequency returns the value from the server")
        func getFrequency() async throws {
            let server = MockRigctldServer { cmd in
                switch cmd {
                case "f": return ["14250000"]
                default: return ["RPRT -1"]
                }
            }
            let port = try await server.start()
            let client = RigctldClient(configuration: .init(port: port))
            try await client.connect()

            let hz = try await client.frequencyHz()
            #expect(hz == 14_250_000)

            await client.disconnect()
            await server.stop()
        }

        @Test("get mode returns mode and passband")
        func getMode() async throws {
            let server = MockRigctldServer { cmd in
                switch cmd {
                case "m": return ["USB", "2400"]
                default: return ["RPRT -1"]
                }
            }
            let port = try await server.start()
            let client = RigctldClient(configuration: .init(port: port))
            try await client.connect()

            let mode = try await client.mode()
            #expect(mode.name == "USB")
            #expect(mode.passbandHz == 2400)

            await client.disconnect()
            await server.stop()
        }

        @Test("set frequency succeeds on RPRT 0")
        func setFrequency() async throws {
            let received = LockedBox<[String]>([])
            let server = MockRigctldServer { cmd in
                received.mutate { $0.append(cmd) }
                return ["RPRT 0"]
            }
            let port = try await server.start()
            let client = RigctldClient(configuration: .init(port: port))
            try await client.connect()

            try await client.setFrequency(7_074_000)
            #expect(received.value.contains("F 7074000"))

            await client.disconnect()
            await server.stop()
        }

        @Test("rig error surfaces as ClientError.rigError")
        func rigError() async throws {
            let server = MockRigctldServer { _ in ["RPRT -9"] }
            let port = try await server.start()
            let client = RigctldClient(configuration: .init(port: port))
            try await client.connect()

            await #expect(throws: RigctldClient.ClientError.self) {
                _ = try await client.frequencyHz()
            }

            await client.disconnect()
            await server.stop()
        }
    }
}

/// Small test helper — `@Sendable` mutable box. Only used where
/// `Responder` closures need to record activity for later assertions.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ transform: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        transform(&_value)
    }
}
