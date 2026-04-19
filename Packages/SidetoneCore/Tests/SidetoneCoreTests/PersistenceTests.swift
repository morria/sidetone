import Foundation
import Testing
@testable import SidetoneCore

@Suite("PersistenceStore")
@MainActor
struct PersistenceStoreTests {
    @Test("roundtrip a station")
    func stationRoundTrip() throws {
        let store = try PersistenceStore(.inMemory)
        try store.saveStation(Station(
            callsign: Callsign("K7ABC")!,
            grid: Grid("FN30AQ"),
            notes: "Brooklyn loop",
            lastHeard: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let all = try store.allStations()
        #expect(all.count == 1)
        #expect(all[0].callsign.value == "K7ABC")
        #expect(all[0].grid?.value == "FN30aq")
        #expect(all[0].notes == "Brooklyn loop")
    }

    @Test("save is an upsert on callsign")
    func upsert() throws {
        let store = try PersistenceStore(.inMemory)
        try store.saveStation(Station(callsign: Callsign("W1ABC")!, notes: "first"))
        try store.saveStation(Station(callsign: Callsign("W1ABC")!, notes: "second"))
        let all = try store.allStations()
        #expect(all.count == 1)
        #expect(all[0].notes == "second")
    }

    @Test("delete a station")
    func deleteStation() throws {
        let store = try PersistenceStore(.inMemory)
        try store.saveStation(Station(callsign: Callsign("K2DEF")!))
        try store.deleteStation(Callsign("K2DEF")!)
        #expect(try store.allStations().isEmpty)
    }

    @Test("append and fetch a transcript scoped to peer")
    func transcript() throws {
        let store = try PersistenceStore(.inMemory)
        let peer1 = Callsign("W1ABC")!
        let peer2 = Callsign("K2DEF")!
        try store.append(Message(timestamp: Date(timeIntervalSince1970: 100), direction: .sent, peer: peer1, body: "one"))
        try store.append(Message(timestamp: Date(timeIntervalSince1970: 200), direction: .received, peer: peer1, body: "two"))
        try store.append(Message(timestamp: Date(timeIntervalSince1970: 150), direction: .received, peer: peer2, body: "other"))

        let p1 = try store.transcript(for: peer1)
        #expect(p1.count == 2)
        #expect(p1.map(\.body) == ["one", "two"])
        let p2 = try store.transcript(for: peer2)
        #expect(p2.map(\.body) == ["other"])
    }

    @Test("deleteTranscript removes only that peer's messages")
    func deleteScoped() throws {
        let store = try PersistenceStore(.inMemory)
        try store.append(Message(direction: .sent, peer: Callsign("A1AA")!, body: "keep"))
        try store.append(Message(direction: .sent, peer: Callsign("B2BB")!, body: "drop"))
        try store.deleteTranscript(for: Callsign("B2BB")!)
        #expect(try store.transcript(for: Callsign("A1AA")!).count == 1)
        #expect(try store.transcript(for: Callsign("B2BB")!).isEmpty)
    }

    @Test("transcript fetch limit is honored")
    func fetchLimit() throws {
        let store = try PersistenceStore(.inMemory)
        let peer = Callsign("Q1QQ")!
        for i in 0..<20 {
            try store.append(Message(
                timestamp: Date(timeIntervalSince1970: Double(i)),
                direction: .sent,
                peer: peer,
                body: "m\(i)"
            ))
        }
        let limited = try store.transcript(for: peer, limit: 5)
        #expect(limited.count == 5)
    }
}
