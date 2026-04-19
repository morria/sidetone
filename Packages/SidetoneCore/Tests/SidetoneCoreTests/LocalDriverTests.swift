import Foundation
import Testing
@testable import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
@Suite("LocalDriver")
struct LocalDriverTests {
    /// Helper: spin up a mock TNC, plus a LocalDriver pointed at it.
    private func makeRig() async throws -> (MockTNCServer, LocalDriver, MockTNCServer.Ports) {
        let server = MockTNCServer()
        let ports = try await server.start()
        let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: Grid("FN30AQ"))
        return (server, driver, ports)
    }

    @Test("connect sends INITIALIZE, MYCALL, GRIDSQUARE, LISTEN FALSE in order")
    func connectHandshake() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        var lines = server.receivedLines.makeAsyncIterator()
        var received: [String] = []
        for _ in 0..<4 {
            if let next = await lines.next() { received.append(next) }
        }
        #expect(received == [
            "INITIALIZE",
            "MYCALL K7ABC",
            "GRIDSQUARE FN30aq",
            "LISTEN FALSE",
        ])
        await driver.shutdown()
        await server.stop()
    }

    @Test("CONNECTED event drives SessionState to .connected")
    func connectedEventUpdatesState() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        try await server.emit("CONNECTED W1ABC 500")

        // Drain events until we see stateChanged(.connected)
        var iter = driver.events.makeAsyncIterator()
        var got: SessionState?
        for _ in 0..<10 {
            guard let ev = await iter.next() else { break }
            if case let .stateChanged(s) = ev, case .connected = s {
                got = s
                break
            }
        }
        if case let .connected(peer, bw, _) = got {
            #expect(peer.value == "W1ABC")
            #expect(bw == 500)
        } else {
            Issue.record("never observed .connected state")
        }

        await driver.shutdown()
        await server.stop()
    }

    @Test("DISCONNECTED event drives SessionState back to .disconnected")
    func disconnectedEvent() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        try await server.emit("CONNECTED W1ABC 500")
        try await server.emit("DISCONNECTED")

        var iter = driver.events.makeAsyncIterator()
        var sawConnected = false
        var sawDisconnectedAfter = false
        for _ in 0..<12 {
            guard let ev = await iter.next() else { break }
            if case .stateChanged(.connected) = ev { sawConnected = true }
            if sawConnected, case .stateChanged(.disconnected) = ev { sawDisconnectedAfter = true; break }
        }
        #expect(sawDisconnectedAfter)

        await driver.shutdown()
        await server.stop()
    }

    @Test("IDF data frame surfaces as .heard with callsign and grid")
    func heardFromIDF() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        try await server.emitFrame(tag: "IDF", payload: Data("KQ6LMN CM87".utf8))

        var iter = driver.events.makeAsyncIterator()
        var heard: (Callsign, Grid?)?
        for _ in 0..<20 {
            guard let ev = await iter.next() else { break }
            if case let .heard(call, grid) = ev {
                heard = (call, grid)
                break
            }
        }
        #expect(heard?.0.value == "KQ6LMN")
        #expect(heard?.1?.value == "CM87")

        await driver.shutdown()
        await server.stop()
    }

    @Test("sendText writes payload on the data port framed [2B length][utf-8]")
    func sendTextOverDataPort() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        try await server.emit("CONNECTED W1ABC 500")

        // Wait for state to propagate to driver so sendText succeeds.
        var stateAttempts = 0
        while !isConnected(await driver.sessionState), stateAttempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            stateAttempts += 1
        }

        try await driver.sendText("hello from brooklyn")

        var iter = server.receivedDataFrames.makeAsyncIterator()
        let payload = await iter.next()
        #expect(payload == Data("hello from brooklyn".utf8))

        await driver.shutdown()
        await server.stop()
    }

    @Test("sendFile queues each chunk on the data port and emits progress")
    func sendFileChunksOnDataPort() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        try await server.emit("CONNECTED W1ABC 500")
        var stateAttempts = 0
        while !isConnected(await driver.sessionState), stateAttempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            stateAttempts += 1
        }

        let payload = Data((0..<1800).map { UInt8($0 & 0xff) })
        Task { try? await driver.sendFile(data: payload, filename: "test.bin", mimeType: "application/octet-stream") }

        var frames: [Data] = []
        var iter = server.receivedDataFrames.makeAsyncIterator()
        let expectedChunks = Int(ceil(Double(payload.count) / Double(FileChunker.defaultChunkPayload)))
        for _ in 0..<expectedChunks {
            if let frame = await iter.next() { frames.append(frame) }
        }
        #expect(frames.count == expectedChunks)

        // Round-trip: decode each received SIDF frame and reassemble.
        guard let (first, _) = try? FileChunkDecoder.decode(frames[0]) else {
            Issue.record("first frame failed to decode"); return
        }
        var reassembler = FileReassembler(first: first)
        for frame in frames.dropFirst() {
            if let (chunk, _) = try? FileChunkDecoder.decode(frame) {
                _ = reassembler.accept(chunk)
            }
        }
        #expect(reassembler.assembled() == payload)

        await driver.shutdown()
        await server.stop()
    }

    @Test("ARQ frames carrying SIDF chunks surface as fileProgress + fileReceived")
    func fileTransferInbound() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        // Seed the session peer so LocalDriver knows who sent the file.
        try await server.emit("CONNECTED W1ABC 500")

        var iter = driver.events.makeAsyncIterator()
        // Drain until we hit .connected so currentPeer is set.
        var connected = false
        for _ in 0..<10 {
            guard let ev = await iter.next() else { break }
            if case .stateChanged(.connected) = ev { connected = true; break }
        }
        #expect(connected)

        let payload = Data((0..<2600).map { UInt8($0 & 0xff) })
        let chunks = FileChunker.chunk(
            payload,
            filename: "image.bin",
            mimeType: "application/octet-stream",
            chunkPayloadSize: 1000
        )
        for chunk in chunks {
            try await server.emitFrame(tag: "ARQ", payload: FileChunkEncoder.encode(chunk))
        }

        var received: (FileTransfer, Data)?
        for _ in 0..<20 {
            guard let ev = await iter.next() else { break }
            if case .fileReceived(let t, let data) = ev {
                received = (t, data)
                break
            }
        }

        #expect(received?.0.filename == "image.bin")
        #expect(received?.0.totalChunks == chunks.count)
        #expect(received?.1 == payload)

        await driver.shutdown()
        await server.stop()
    }

    @Test("initiateCall transitions to .connecting and sends ARQBW then ARQCALL")
    func initiateCall() async throws {
        let (server, driver, _) = try await makeRig()
        try await driver.connect()
        await server.awaitClient()

        // Drain the handshake lines first so our assertion sees the new ones.
        var lines = server.receivedLines.makeAsyncIterator()
        for _ in 0..<4 { _ = await lines.next() }

        try await driver.initiateCall(to: Callsign("W1ABC")!, bandwidth: .hz500(forced: false), repeats: 3)

        let l1 = await lines.next()
        let l2 = await lines.next()
        #expect(l1 == "ARQBW 500MAX")
        #expect(l2 == "ARQCALL W1ABC 3")
        if case .connecting(let peer, _) = await driver.sessionState {
            #expect(peer.value == "W1ABC")
        } else {
            Issue.record("expected .connecting")
        }

        await driver.shutdown()
        await server.stop()
    }
}

}

private func isConnected(_ s: SessionState) -> Bool {
    if case .connected = s { true } else { false }
}

extension IntegrationTests {
@Suite("AppState reducer")
@MainActor
struct AppStateTests {
    @Test("connect path: state.connected populates stations list not required; transcript created on receive")
    func transcriptOnReceive() async throws {
        let server = MockTNCServer()
        let ports = try await server.start()
        let tnc = TNCClient(configuration: .init(host: "127.0.0.1", commandPort: ports.command))
        let driver = LocalDriver(tnc: tnc, myCall: Callsign("K7ABC")!, grid: nil)
        let state = AppState()
        state.attach(driver, identity: .init(callsign: Callsign("K7ABC")!))
        try await driver.connect()
        await server.awaitClient()

        try await server.emit("CONNECTED W1ABC 500")

        // The command port (CONNECTED) and data port (ARQ) are independent
        // TCP connections — delivery races if we don't gate on the driver
        // processing CONNECTED first. Real ardopcf always sequences this in
        // the FSM; the race here is a test-only artifact.
        var stateAttempts = 0
        while !isConnected(state.sessionState), stateAttempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            stateAttempts += 1
        }

        try await server.emitFrame(tag: "ARQ", payload: Data("hi from vermont".utf8))

        var attempts = 0
        while state.transcripts[Callsign("W1ABC")!]?.isEmpty ?? true, attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }

        let msgs = state.transcripts[Callsign("W1ABC")!] ?? []
        #expect(msgs.count == 1)
        #expect(msgs.first?.body == "hi from vermont")
        #expect(msgs.first?.direction == .received)

        await state.detach()
        await server.stop()
    }

    @Test("saveStation upserts by callsign")
    func saveStation() {
        let state = AppState()
        state.saveStation(Station(callsign: Callsign("W1ABC")!, notes: "vermont"))
        state.saveStation(Station(callsign: Callsign("W1ABC")!, notes: "updated"))
        #expect(state.stations.count == 1)
        #expect(state.stations[0].notes == "updated")
        state.removeStation(Callsign("W1ABC")!)
        #expect(state.stations.isEmpty)
    }
}
}
