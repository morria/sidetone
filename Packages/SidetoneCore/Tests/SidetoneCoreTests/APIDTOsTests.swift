import Foundation
import Testing
@testable import SidetoneCore

@Suite("APIv1 DTOs")
struct APIDTOsTests {
    @Test("StationDTO round-trips through Station value type")
    func stationRoundTrip() {
        let s = Station(
            callsign: Callsign("K7ABC")!,
            grid: Grid("FN30AQ"),
            notes: "loop in brooklyn",
            lastHeard: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let dto = APIv1.StationDTO(s)
        #expect(dto.callsign == "K7ABC")
        #expect(dto.grid == "FN30aq")
        #expect(dto.asValue == s)
    }

    @Test("MessageDTO round-trips through Message")
    func messageRoundTrip() {
        let m = Message(
            timestamp: Date(timeIntervalSince1970: 123),
            direction: .received,
            peer: Callsign("W1ABC")!,
            body: "hello"
        )
        let dto = APIv1.MessageDTO(m)
        #expect(dto.direction == "received")
        #expect(dto.asValue?.body == "hello")
        #expect(dto.asValue?.direction == .received)
    }

    @Test("SessionStateDTO encodes each variant and decodes cleanly")
    func sessionStateVariants() throws {
        let states: [SessionState] = [
            .disconnected,
            .listening,
            .connecting(to: Callsign("W1ABC")!, startedAt: Date(timeIntervalSince1970: 1)),
            .connected(peer: Callsign("W1ABC")!, bandwidth: 500, since: Date(timeIntervalSince1970: 2)),
            .disconnecting,
            .error("oops"),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for state in states {
            let dto = APIv1.SessionStateDTO(state)
            let data = try enc.encode(dto)
            let round = try dec.decode(APIv1.SessionStateDTO.self, from: data)
            #expect(round.asValue == state)
        }
    }

    @Test("EventEnvelope preserves an arbitrary payload round-trip")
    func envelopeRoundTrip() throws {
        let payload = APIv1.LinkQualityEvent(snr: 4, quality: 72)
        let envelope = try APIv1.EventEnvelope(kind: APIv1.EventKind.linkQuality, payload: payload)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(APIv1.EventEnvelope.self, from: data)
        #expect(decoded.kind == APIv1.EventKind.linkQuality)
        let reparsed = try decoded.data.decode(as: APIv1.LinkQualityEvent.self)
        #expect(reparsed.snr == 4)
        #expect(reparsed.quality == 72)
    }

    @Test("Unknown kind still decodes — client can skip instead of failing")
    func unknownKindSurvives() throws {
        let json = """
        {"kind":"brand_new_event_v7","data":{"weird":[1,2,3]}}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIv1.EventEnvelope.self, from: json)
        #expect(envelope.kind == "brand_new_event_v7")
    }

    @Test("ErrorResponse shape is stable")
    func errorResponseShape() throws {
        let err = APIv1.ErrorResponse(code: "not_paired", message: "unknown device")
        let data = try JSONEncoder().encode(err)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(obj?["code"] == "not_paired")
        #expect(obj?["message"] == "unknown device")
    }
}
