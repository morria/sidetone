import Testing
@testable import SidetoneCore

@Suite("TNCCommand wire format")
struct TNCCommandsTests {
    @Test("every command is terminated with a lone CR")
    func allCommandsEndInCR() {
        let samples: [TNCCommand] = [
            .initialize,
            .myCall(Callsign("K7ABC")!),
            .gridSquare(Grid("FN30AQ")!),
            .arqBandwidth(.hz500(forced: false)),
            .arqBandwidth(.hz2000(forced: true)),
            .arqCall(Callsign("W1XYZ")!, repeats: 3),
            .listen(true),
            .listen(false),
            .disconnect,
            .abort,
            .sendID,
            .cwID(true),
            .ping(Callsign("K7ABC")!, repeats: 2),
            .busyDetect(false),
            .autoBreak(true),
            .protocolMode("ARQ"),
        ]
        for cmd in samples {
            let wire = cmd.wireLine()
            #expect(wire.hasSuffix("\r"))
            #expect(!wire.dropLast().contains("\r"))
            #expect(!wire.contains("\n"))
        }
    }

    @Test("specific wire strings match ardopcf expectations")
    func specificFormats() {
        #expect(TNCCommand.initialize.wireLine() == "INITIALIZE\r")
        #expect(TNCCommand.myCall(Callsign("K7ABC")!).wireLine() == "MYCALL K7ABC\r")
        #expect(TNCCommand.gridSquare(Grid("FN30AQ")!).wireLine() == "GRIDSQUARE FN30aq\r")
        #expect(TNCCommand.listen(true).wireLine() == "LISTEN TRUE\r")
        #expect(TNCCommand.listen(false).wireLine() == "LISTEN FALSE\r")
        #expect(TNCCommand.arqBandwidth(.hz500(forced: false)).wireLine() == "ARQBW 500MAX\r")
        #expect(TNCCommand.arqBandwidth(.hz2000(forced: true)).wireLine() == "ARQBW 2000FORCED\r")
        #expect(TNCCommand.arqCall(Callsign("W1XYZ")!, repeats: 3).wireLine() == "ARQCALL W1XYZ 3\r")
        #expect(TNCCommand.ping(Callsign("N3GHI")!, repeats: 2).wireLine() == "PING N3GHI 2\r")
        #expect(TNCCommand.sendID.wireLine() == "SENDID\r")
        #expect(TNCCommand.disconnect.wireLine() == "DISCONNECT\r")
        #expect(TNCCommand.abort.wireLine() == "ABORT\r")
    }
}
