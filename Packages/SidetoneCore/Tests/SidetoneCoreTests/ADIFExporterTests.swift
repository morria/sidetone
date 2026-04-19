import Foundation
import Testing
@testable import SidetoneCore

@Suite("ADIF export")
struct ADIFExporterTests {
    @Test("coalesces tight message cluster into a single QSO")
    func singleQSO() {
        let peer = Callsign("W1ABC")!
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = [
            Message(timestamp: t0,            direction: .received, peer: peer, body: "hello"),
            Message(timestamp: t0.addingTimeInterval(60),  direction: .sent,     peer: peer, body: "hi"),
            Message(timestamp: t0.addingTimeInterval(120), direction: .received, peer: peer, body: "73"),
        ]
        let exporter = ADIFExporter()
        let qsos = exporter.coalesce(messages)
        #expect(qsos.count == 1)
        #expect(qsos[0].peer == peer)
        #expect(qsos[0].rxCount == 2)
        #expect(qsos[0].txCount == 1)
    }

    @Test("splits QSOs on gap longer than quietGap")
    func splitsOnGap() {
        let peer = Callsign("W1ABC")!
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let gap: TimeInterval = 3 * 60 * 60  // 3 hours
        let messages = [
            Message(timestamp: t0,          direction: .sent, peer: peer, body: "a"),
            Message(timestamp: t0.addingTimeInterval(gap), direction: .sent, peer: peer, body: "b"),
        ]
        let qsos = ADIFExporter(quietGap: 2 * 60 * 60).coalesce(messages)
        #expect(qsos.count == 2)
    }

    @Test("groups by peer — two peers give two QSOs")
    func twoPeers() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = Callsign("W1ABC")!
        let b = Callsign("K2DEF")!
        let messages = [
            Message(timestamp: t0, direction: .sent, peer: a, body: "first"),
            Message(timestamp: t0.addingTimeInterval(30), direction: .sent, peer: b, body: "second"),
        ]
        let qsos = ADIFExporter().coalesce(messages)
        #expect(qsos.count == 2)
        #expect(Set(qsos.map(\.peer)) == Set([a, b]))
    }

    @Test("ADIF output contains a header + a well-formed record")
    func adifShape() {
        let peer = Callsign("W1ABC")!
        let t0 = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let messages = [
            Message(timestamp: t0, direction: .sent, peer: peer, body: "test")
        ]
        let adif = ADIFExporter(myCall: Callsign("K7ABC"), myGrid: Grid("FN30AQ")).export(messages)

        #expect(adif.contains("<ADIF_VER:5>3.1.5"))
        #expect(adif.contains("<PROGRAMID:8>Sidetone"))
        #expect(adif.contains("<eoh>"))
        #expect(adif.contains("<CALL:5>W1ABC"))
        #expect(adif.contains("<MODE:5>ARDOP"))
        #expect(adif.contains("<OPERATOR:5>K7ABC"))
        #expect(adif.contains("<MY_GRIDSQUARE:6>FN30aq"))
        #expect(adif.contains("<QSO_DATE:8>20231114"))
        #expect(adif.contains("<TIME_ON:6>221320"))
        #expect(adif.contains("<eor>"))
    }

    @Test("empty message list produces only a header")
    func emptyList() {
        let adif = ADIFExporter().export([])
        #expect(adif.contains("<eoh>"))
        #expect(adif.contains("<eor>") == false)
    }
}
