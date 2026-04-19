import Foundation
import Testing
@testable import SidetoneServer
import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    @Suite("TLS round-trip")
    @MainActor
    struct TLSRoundTripSuite {
        @Test("A pinned client can talk to a TLS server; an unpinned one cannot")
        func pinningWorks() async throws {
            let mockTNC = MockTNCServer()
            let ports = try await mockTNC.start()
            let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
            let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
            try await driver.connect()
            await mockTNC.awaitClient()

            let host = ServerHost(driver: driver, store: nil, identity: .init(callsign: Callsign("K7ABC")!))
            await host.start()
            let router = Endpoints.routes(host: host, store: nil, pairing: nil)

            let material = try CertificateManager.generate(commonName: "localhost")
            let server = SidetoneServer(
                configuration: .init(
                    host: "127.0.0.1",
                    port: 0,
                    tls: .init(
                        pemCertificate: material.pemCertificate,
                        pemPrivateKey: material.pemPrivateKey
                    )
                ),
                host: host,
                router: router
            )
            let port = try await server.start()

            let url = URL(string: "https://localhost:\(port)/api/v1/status")!

            // Pinned session: should succeed.
            let pinned = PinnedTLSDelegate(expectedFingerprintSHA256: material.fingerprintSHA256)
            let goodSession = URLSession(configuration: .ephemeral, delegate: pinned, delegateQueue: nil)
            let (_, goodResponse) = try await goodSession.data(from: url)
            #expect((goodResponse as? HTTPURLResponse)?.statusCode == 200)

            // Wrong-fingerprint session: should fail.
            let wrongPin = PinnedTLSDelegate(expectedFingerprintSHA256: String(repeating: "00", count: 32))
            let badSession = URLSession(configuration: .ephemeral, delegate: wrongPin, delegateQueue: nil)
            await #expect(throws: (any Error).self) {
                _ = try await badSession.data(from: url)
            }

            await server.stop()
            await mockTNC.stop()
        }
    }
}
