import Foundation
import Testing
@testable import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    /// Integration tests running `TNCClient` against a real loopback TCP
    /// server (`MockTNCServer`). Exercises split-read buffering, command
    /// and event paths, and disconnect tear-down end-to-end.
    @Suite("TNCClient ↔ MockTNCServer")
    struct TNCClientSuite {
    @Test("handshake: connect and receive a NEWSTATE event")
    func connectAndReceiveEvent() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()
        defer { Task { await server.stop() } }

        let client = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        try await client.connect()
        await server.awaitClient()

        try await server.emit("NEWSTATE IRS")

        var iterator = client.events.makeAsyncIterator()
        let ev = await iterator.next()
        #expect(ev == .newState("IRS"))

        await client.disconnect()
        await server.stop()
    }

    @Test("client command arrives at server byte-for-byte with trailing CR")
    func commandRoundTrip() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()

        let client = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        try await client.connect()
        await server.awaitClient()

        try await client.send(.myCall(Callsign("K7ABC")!))

        var lines = server.receivedLines.makeAsyncIterator()
        let received = await lines.next()
        #expect(received == "MYCALL K7ABC")

        await client.disconnect()
        await server.stop()
    }

    @Test("data port frame round-trip")
    func dataFrameRoundTrip() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()

        let client = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        try await client.connect()
        await server.awaitClient()

        try await server.emitFrame(tag: "ARQ", payload: Data("hello over the air".utf8))

        var iterator = client.frames.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.kind == .arq)
        #expect(frame?.payload == Data("hello over the air".utf8))

        await client.disconnect()
        await server.stop()
    }

    @Test("split-read tolerance: a single frame delivered in 1-byte chunks still parses")
    func dataFrameSplitReads() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()

        let client = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        try await client.connect()
        await server.awaitClient()

        // Encode the frame on our side, feed the raw bytes one at a time.
        let expected = Data("split across packet boundaries".utf8)
        let wire = DataFrameEncoder.encode(tag: "FEC", payload: expected)
        for byte in wire {
            try await server.emitRawDataBytes(Data([byte]))
        }

        var iterator = client.frames.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.kind == .fec)
        #expect(frame?.payload == expected)

        await client.disconnect()
        await server.stop()
    }

    @Test("disconnect tears down promptly — subsequent send throws notConnected")
    func disconnectSemantics() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()

        let client = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        try await client.connect()
        await server.awaitClient()
        await client.disconnect()

        await #expect(throws: TNCClient.ConnectionError.self) {
            try await client.send(.sendID)
        }

        await server.stop()
    }
    }
}
