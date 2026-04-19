import Foundation
import Testing
@testable import SidetoneServer
import SidetoneCore
import SidetoneTestSupport

/// End-to-end parity test from the spec's cross-platform requirement:
/// "a suite that runs against both LocalDriver and RemoteDriver and
/// asserts identical observable behavior." Here we wire the full chain
/// — MockTNCServer → LocalDriver → ServerHost → SidetoneServer →
/// WebSocket → RemoteDriver — and confirm events round-trip.
extension IntegrationTests {
    @Suite("RemoteDriver end-to-end")
    @MainActor
    struct RemoteDriverSuite {
        @Test("WebSocket upgrade works: client receives initial state snapshot on connect")
        func websocketSmokeTest() async throws {
            let rig = try await makeRig()
            let url = URL(string: "ws://127.0.0.1:\(rig.port)/api/v1/events")!
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()

            let msg = try await task.receive()
            let data: Data = {
                switch msg {
                case .data(let d): return d
                case .string(let s): return Data(s.utf8)
                @unknown default: return Data()
                }
            }()
            let envelope = try JSONDecoder().decode(APIv1.EventEnvelope.self, from: data)
            #expect(envelope.kind == APIv1.EventKind.stateChanged)

            task.cancel(with: .goingAway, reason: nil)
            await rig.teardown()
        }

        @Test("CONNECTED on the TNC surfaces as stateChanged(.connected) on the remote client")
        func connectedPropagates() async throws {
            let rig = try await makeRig()

            // Subscribe to remote events BEFORE triggering the
            // CONNECTED line, so we don't miss the broadcast.
            let remote = rig.remote
            try await remote.connect()

            var iter = remote.events.makeAsyncIterator()
            // First event is the initial state snapshot the server
            // gives on subscribe — drain it.
            _ = await iter.next()

            try await rig.mockTNC.emit("CONNECTED W1ABC 500")

            var sawConnected = false
            for _ in 0..<15 {
                guard let ev = await iter.next() else { break }
                if case .stateChanged(.connected(let peer, let bw, _)) = ev, peer.value == "W1ABC", bw == 500 {
                    sawConnected = true
                    break
                }
            }
            #expect(sawConnected)

            await rig.teardown()
        }

        // MARK: - Rig

        private struct Rig {
            let server: SidetoneServer
            let mockTNC: MockTNCServer
            let remote: RemoteDriver
            let port: Int

            func teardown() async {
                await remote.shutdown()
                await server.stop()
                await mockTNC.stop()
            }
        }

        private func makeRig() async throws -> Rig {
            let mockTNC = MockTNCServer()
            let ports = try await mockTNC.start()
            let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
            let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
            try await driver.connect()
            await mockTNC.awaitClient()

            let host = ServerHost(
                driver: driver,
                store: nil,
                identity: .init(callsign: Callsign("K7ABC")!)
            )
            await host.start()
            let router = Endpoints.routes(host: host, store: nil)
            let server = SidetoneServer(
                configuration: .init(host: "127.0.0.1", port: 0),
                host: host,
                router: router
            )
            let port = try await server.start()

            let remote = RemoteDriver(configuration: .init(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!
            ))
            return Rig(server: server, mockTNC: mockTNC, remote: remote, port: port)
        }
    }
}
