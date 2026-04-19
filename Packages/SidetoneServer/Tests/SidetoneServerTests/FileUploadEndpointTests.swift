import Foundation
import Testing
@testable import SidetoneServer
import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    @Suite("File upload endpoint")
    @MainActor
    struct FileUploadSuite {
        @Test("POST /api/v1/files with raw body reaches the TNC data port as SIDF chunks")
        func uploadRoundTrip() async throws {
            let mockTNC = MockTNCServer()
            let ports = try await mockTNC.start()
            let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
            let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
            try await driver.connect()
            await mockTNC.awaitClient()

            // Seed the peer so sendFile clears the "notInSession" guard.
            try await mockTNC.emit("CONNECTED W1ABC 500")
            var attempts = 0
            while attempts < 100 {
                if case .connected = await driver.sessionState { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
                attempts += 1
            }

            let host = ServerHost(driver: driver, store: nil, identity: .init(callsign: Callsign("K7ABC")!))
            await host.start()
            let router = Endpoints.routes(host: host, store: nil, pairing: nil)
            let server = SidetoneServer(
                configuration: .init(host: "127.0.0.1", port: 0),
                host: host,
                router: router
            )
            let port = try await server.start()

            let payload = Data((0..<1500).map { UInt8($0 & 0xff) })
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/files")!)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("test.bin", forHTTPHeaderField: "X-Sidetone-Filename")
            request.setValue("application/octet-stream", forHTTPHeaderField: "X-Sidetone-MimeType")
            request.httpBody = payload

            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 202)

            // The mock TNC's data port should have received the file
            // chunks. Reassemble and confirm byte-for-byte match.
            var iter = mockTNC.receivedDataFrames.makeAsyncIterator()
            let expected = Int(ceil(Double(payload.count) / Double(FileChunker.defaultChunkPayload)))
            var frames: [Data] = []
            for _ in 0..<expected {
                if let f = await iter.next() { frames.append(f) }
            }
            #expect(frames.count == expected)

            let firstChunk = try FileChunkDecoder.decode(frames[0]).0
            var reassembler = FileReassembler(first: firstChunk)
            for frame in frames.dropFirst() {
                _ = reassembler.accept(try FileChunkDecoder.decode(frame).0)
            }
            #expect(reassembler.assembled() == payload)
            #expect(reassembler.filename == "test.bin")

            await server.stop()
            await mockTNC.stop()
        }

        @Test("RemoteDriver.sendFile lands as SIDF chunks on the TNC data port")
        func remoteDriverSendFile() async throws {
            let mockTNC = MockTNCServer()
            let ports = try await mockTNC.start()
            let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
            let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
            try await driver.connect()
            await mockTNC.awaitClient()
            try await mockTNC.emit("CONNECTED W1ABC 500")
            var attempts = 0
            while attempts < 100 {
                if case .connected = await driver.sessionState { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
                attempts += 1
            }

            let host = ServerHost(driver: driver, store: nil, identity: .init(callsign: Callsign("K7ABC")!))
            await host.start()
            let server = SidetoneServer(
                configuration: .init(host: "127.0.0.1", port: 0),
                host: host,
                router: Endpoints.routes(host: host, store: nil, pairing: nil)
            )
            let port = try await server.start()

            let remote = RemoteDriver(configuration: .init(baseURL: URL(string: "http://127.0.0.1:\(port)")!))
            try await remote.connect()

            let payload = Data((0..<900).map { UInt8($0 & 0xff) })
            try await remote.sendFile(data: payload, filename: "photo.jpg", mimeType: "image/jpeg")

            var iter = mockTNC.receivedDataFrames.makeAsyncIterator()
            guard let frame = await iter.next() else {
                Issue.record("no frame received")
                return
            }
            let (chunk, _) = try FileChunkDecoder.decode(frame)
            #expect(chunk.filename == "photo.jpg")
            #expect(chunk.mimeType == "image/jpeg")
            #expect(chunk.totalBytes == payload.count)

            await remote.shutdown()
            await server.stop()
            await mockTNC.stop()
        }
    }
}
