import Foundation
import Testing
@testable import SidetoneServer
import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    @Suite("Pairing + auth")
    @MainActor
    struct PairingSuite {
        @Test("correct code exchanges for a token; wrong code and expired both rejected")
        func codeExchange() async throws {
            let registry = PairingRegistry()
            let code = await registry.beginPairing(ttl: 5)
            let dev = try await registry.exchange(code: code, deviceName: "iPhone")
            #expect(!dev.token.isEmpty)

            // Pairing auto-closes after success — a second exchange with
            // the same code fails because the registry is no longer in
            // pairing mode.
            await #expect(throws: PairingRegistry.PairingError.self) {
                _ = try await registry.exchange(code: code, deviceName: "iPhone-2")
            }

            // Wrong code (fresh pairing window).
            let code2 = await registry.beginPairing(ttl: 5)
            await #expect(throws: PairingRegistry.PairingError.self) {
                _ = try await registry.exchange(code: "999999", deviceName: "iPhone")
            }
            // And the real code still works.
            _ = try await registry.exchange(code: code2, deviceName: "iPhone")
        }

        @Test("auth middleware: /status without token → 401; with token → 200")
        func authGating() async throws {
            let rig = try await makeRig()

            let statusURL = URL(string: "http://127.0.0.1:\(rig.port)/api/v1/status")!

            // Unauthorized
            let (_, r1) = try await URLSession.shared.data(from: statusURL)
            #expect((r1 as? HTTPURLResponse)?.statusCode == 401)

            // Pair, then retry with bearer.
            let code = await rig.registry.beginPairing()
            let client = PairingClient(baseURL: URL(string: "http://127.0.0.1:\(rig.port)")!)
            let pair = try await client.pair(code: code, deviceName: "test")

            var request = URLRequest(url: statusURL)
            request.setValue("Bearer \(pair.token)", forHTTPHeaderField: "Authorization")
            let (_, r2) = try await URLSession.shared.data(for: request)
            #expect((r2 as? HTTPURLResponse)?.statusCode == 200)

            await rig.teardown()
        }

        // MARK: - Rig

        struct Rig {
            let server: SidetoneServer
            let mockTNC: MockTNCServer
            let registry: PairingRegistry
            let port: Int

            func teardown() async {
                await server.stop()
                await mockTNC.stop()
            }
        }

        func makeRig() async throws -> Rig {
            let mockTNC = MockTNCServer()
            let ports = try await mockTNC.start()
            let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
            let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
            try await driver.connect()
            await mockTNC.awaitClient()

            let host = ServerHost(driver: driver, store: nil, identity: .init(callsign: Callsign("K7ABC")!))
            await host.start()
            let registry = PairingRegistry()
            let router = Endpoints.routes(host: host, store: nil, pairing: registry)
            let server = SidetoneServer(
                configuration: .init(host: "127.0.0.1", port: 0),
                host: host,
                router: router
            )
            let port = try await server.start()
            return Rig(server: server, mockTNC: mockTNC, registry: registry, port: port)
        }
    }
}
