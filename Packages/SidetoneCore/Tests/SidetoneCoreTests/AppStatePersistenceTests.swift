import Foundation
import Testing
@testable import SidetoneCore

@Suite("AppState + PersistenceStore")
@MainActor
struct AppStatePersistenceTests {
    @Test("saving a station in AppState persists through the store")
    func saveThroughStore() throws {
        let store = try PersistenceStore(.inMemory)
        let state = AppState(store: store)
        state.saveStation(Station(callsign: Callsign("K7ABC")!, notes: "first"))

        // A brand-new AppState backed by the same store should see it.
        let state2 = AppState(store: store)
        #expect(state2.stations.count == 1)
        #expect(state2.stations[0].callsign.value == "K7ABC")
    }

    @Test("removeStation persists through the store")
    func removeThroughStore() throws {
        let store = try PersistenceStore(.inMemory)
        let state = AppState(store: store)
        state.saveStation(Station(callsign: Callsign("K2DEF")!))
        state.removeStation(Callsign("K2DEF")!)
        let state2 = AppState(store: store)
        #expect(state2.stations.isEmpty)
    }

    @Test("loadTranscript reads persisted messages for the given peer")
    func loadTranscript() throws {
        let store = try PersistenceStore(.inMemory)
        let peer = Callsign("W1ABC")!
        try store.append(Message(timestamp: Date(timeIntervalSince1970: 1), direction: .sent, peer: peer, body: "earlier"))
        try store.append(Message(timestamp: Date(timeIntervalSince1970: 2), direction: .received, peer: peer, body: "later"))

        let state = AppState(store: store)
        #expect(state.transcripts[peer] == nil)
        state.loadTranscript(for: peer)
        #expect(state.transcripts[peer]?.count == 2)
        #expect(state.transcripts[peer]?.map(\.body) == ["earlier", "later"])
    }
}
