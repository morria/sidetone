import Testing
@testable import SidetoneCore

@Suite("Callsign")
struct CallsignTests {
    @Test("uppercases on construction")
    func uppercases() {
        #expect(Callsign("k7abc")?.value == "K7ABC")
        #expect(Callsign(" w1xyz ")?.value == "W1XYZ")
    }

    @Test("accepts portable suffixes")
    func portableSuffixes() {
        #expect(Callsign("K7ABC/P")?.value == "K7ABC/P")
        #expect(Callsign("K7ABC/M")?.value == "K7ABC/M")
        #expect(Callsign("K7ABC/MM")?.value == "K7ABC/MM")
        #expect(Callsign("K7ABC/AM")?.value == "K7ABC/AM")
    }

    @Test("accepts unusual but real callsigns")
    func realCallsigns() {
        // Real DX prefixes used in actual QSOs.
        #expect(Callsign("3DA0RU") != nil)  // Eswatini
        #expect(Callsign("HV0A") != nil)    // Vatican
        #expect(Callsign("VP8ORK") != nil)  // South Orkney
        #expect(Callsign("JA1ABC/1") != nil)
    }

    @Test("rejects empty, all-letters, all-digits, too-long")
    func rejections() {
        #expect(Callsign("") == nil)
        #expect(Callsign("ABCDE") == nil)   // no digit
        #expect(Callsign("12345") == nil)   // no letter
        #expect(Callsign(String(repeating: "A1", count: 10)) == nil)
    }

    @Test("rejects non-ASCII")
    func nonASCII() {
        #expect(Callsign("K7ÆBC") == nil)
        #expect(Callsign("東京1") == nil)
    }
}
