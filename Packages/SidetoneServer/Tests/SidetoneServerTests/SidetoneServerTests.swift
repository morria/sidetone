import Foundation
import Testing
@testable import SidetoneServer
import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
@Suite("SidetoneServer")
struct SidetoneServerTests {
    @Test("GET /api/v1/status returns a valid StatusResponse")
    func statusEndpoint() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.teardown() } }

        let url = URL(string: "http://127.0.0.1:\(rig.port)/api/v1/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = try decoder.decode(APIv1.StatusResponse.self, from: data)
        #expect(body.myCall == "K7ABC")

        await rig.teardown()
    }

    @Test("POST /api/v1/stations saves a station and GET returns it")
    func stationsCRUD() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.teardown() } }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(APIv1.StationDTO(callsign: "W1ABC", grid: "FN30aq", notes: "vermont"))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(rig.port)/api/v1/stations")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        let postStatus = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(postStatus == 201)

        // Round-trip via GET.
        let getURL = URL(string: "http://127.0.0.1:\(rig.port)/api/v1/stations")!
        let (getData, _) = try await URLSession.shared.data(from: getURL)
        let list = try JSONDecoder().decode(APIv1.StationsResponse.self, from: getData)
        #expect(list.stations.contains { $0.callsign == "W1ABC" })

        await rig.teardown()
    }

    @Test("GET /api/v1/log returns persisted messages newest-first")
    @MainActor
    func logEndpoint() async throws {
        let rig = try await makeRig()
        try rig.store.append(Message(
            timestamp: Date(timeIntervalSince1970: 100),
            direction: .sent,
            peer: Callsign("W1ABC")!,
            body: "first"
        ))
        try rig.store.append(Message(
            timestamp: Date(timeIntervalSince1970: 200),
            direction: .received,
            peer: Callsign("K2DEF")!,
            body: "second"
        ))

        let url = URL(string: "http://127.0.0.1:\(rig.port)/api/v1/log")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = try decoder.decode(APIv1.MessagesResponse.self, from: data)
        #expect(body.messages.map(\.body) == ["second", "first"])

        await rig.teardown()
    }

    @Test("POST /api/v1/connect with bad callsign returns 400")
    func connectValidation() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.teardown() } }

        let payload = try JSONEncoder().encode(APIv1.ConnectRequest(callsign: "123"))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(rig.port)/api/v1/connect")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(status == 400)

        await rig.teardown()
    }

    // MARK: - Rig

    @MainActor
    private struct Rig {
        let server: SidetoneServer
        let mockTNC: MockTNCServer
        let store: PersistenceStore
        let port: Int

        func teardown() async {
            await server.stop()
            await mockTNC.stop()
        }
    }

    @MainActor
    private func makeRig() async throws -> Rig {
        let mockTNC = MockTNCServer()
        let ports = try await mockTNC.start()
        let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: Grid("FN30AQ"))
        try await driver.connect()
        await mockTNC.awaitClient()

        let store = try PersistenceStore(.inMemory)
        let host = ServerHost(
            driver: driver,
            store: store,
            identity: .init(callsign: Callsign("K7ABC")!, grid: Grid("FN30AQ"))
        )
        await host.start()
        let router = Endpoints.routes(host: host, store: store)
        let server = SidetoneServer(
            configuration: .init(host: "127.0.0.1", port: 0),
            host: host,
            router: router
        )
        let port = try await server.start()
        return Rig(server: server, mockTNC: mockTNC, store: store, port: port)
    }
}
}
