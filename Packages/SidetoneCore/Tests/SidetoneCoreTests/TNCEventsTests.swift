import Testing
@testable import SidetoneCore

@Suite("TNCEvent parser")
struct TNCEventsTests {
    @Test("state and newstate")
    func stateEvents() {
        #expect(TNCEventParser.parse("NEWSTATE IRS") == .newState("IRS"))
        #expect(TNCEventParser.parse("STATE DISC") == .state("DISC"))
        #expect(TNCEventParser.parse("NEWSTATE ") == .newState(""))
    }

    @Test("buffer with integer")
    func buffer() {
        #expect(TNCEventParser.parse("BUFFER 0") == .buffer(0))
        #expect(TNCEventParser.parse("BUFFER 4096") == .buffer(4096))
    }

    @Test("connected callsign and bandwidth")
    func connected() {
        let ev = TNCEventParser.parse("CONNECTED W1ABC 500")
        #expect(ev == .connected(peer: Callsign("W1ABC")!, bandwidth: 500))
    }

    @Test("disconnected, pending, cancelpending")
    func simpleKeywords() {
        #expect(TNCEventParser.parse("DISCONNECTED") == .disconnected)
        #expect(TNCEventParser.parse("PENDING") == .pending)
        #expect(TNCEventParser.parse("CANCELPENDING") == .cancelPending)
    }

    @Test("PTT and BUSY")
    func ptt() {
        #expect(TNCEventParser.parse("PTT TRUE") == .ptt(true))
        #expect(TNCEventParser.parse("PTT FALSE") == .ptt(false))
        #expect(TNCEventParser.parse("BUSY TRUE") == .busy(true))
        #expect(TNCEventParser.parse("BUSY FALSE") == .busy(false))
    }

    @Test("pingack numeric fields")
    func pingack() {
        #expect(TNCEventParser.parse("PINGACK 4 72") == .pingAck(snr: 4, quality: 72))
        #expect(TNCEventParser.parse("PINGACK -3 10") == .pingAck(snr: -3, quality: 10))
    }

    @Test("ping with caller>target")
    func ping() {
        let ev = TNCEventParser.parse("PING K7ABC>W1XYZ 5 80")
        #expect(ev == .ping(from: Callsign("K7ABC")!, to: Callsign("W1XYZ")!, snr: 5, quality: 80))
    }

    @Test("rejected and fault")
    func rejected() {
        #expect(TNCEventParser.parse("REJECTEDBW W1ABC") == .rejectedBW(Callsign("W1ABC")!))
        #expect(TNCEventParser.parse("REJECTEDBUSY W1ABC") == .rejectedBusy(Callsign("W1ABC")!))
        #expect(TNCEventParser.parse("FAULT Bad command 'FOOBAR'") == .fault("Bad command 'FOOBAR'"))
    }

    @Test("unknown keyword becomes ack — preserves round-trip for set echoes")
    func ackFallback() {
        if case let .ack(keyword, body) = TNCEventParser.parse("MYCALL now K7ABC") {
            #expect(keyword == "MYCALL")
            #expect(body == "now K7ABC")
        } else {
            Issue.record("expected .ack")
        }
    }

    @Test("empty line becomes empty unparsed")
    func emptyLine() {
        #expect(TNCEventParser.parse("") == .unparsed(""))
    }
}

@Suite("LineAccumulator")
struct LineAccumulatorTests {
    @Test("splits on CR")
    func splitsOnCR() {
        var acc = LineAccumulator()
        let lines = acc.feed(Array("ALPHA\rBETA\r".utf8))
        #expect(lines == ["ALPHA", "BETA"])
    }

    @Test("holds partial line across feeds")
    func partialAcross() {
        var acc = LineAccumulator()
        var out = acc.feed(Array("CONNE".utf8))
        #expect(out.isEmpty)
        out = acc.feed(Array("CTED W1ABC 500\rNEWSTATE IRS\r".utf8))
        #expect(out == ["CONNECTED W1ABC 500", "NEWSTATE IRS"])
    }

    @Test("tolerates CRLF and LF alone")
    func lineEndings() {
        var acc = LineAccumulator()
        #expect(acc.feed(Array("A\r\nB\nC\r".utf8)) == ["A", "B", "C"])
    }
}
