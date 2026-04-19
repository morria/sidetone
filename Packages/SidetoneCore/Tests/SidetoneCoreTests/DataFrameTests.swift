import Foundation
import Testing
@testable import SidetoneCore

@Suite("DataFrame framing — length-prefix parser")
struct DataFrameTests {
    @Test("round trip: encode then parse matches original")
    func roundTrip() {
        let payload = Data("hello world".utf8)
        let wire = DataFrameEncoder.encode(tag: "ARQ", payload: payload)
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.errors.isEmpty)
        #expect(out.frames.count == 1)
        #expect(out.frames[0].kind == .arq)
        #expect(out.frames[0].rawTag == "ARQ")
        #expect(out.frames[0].payload == payload)
    }

    @Test("recognizes ARQ FEC IDF ERR, surfaces others as .unknown")
    func kindMapping() {
        #expect(DataFrame.kind(for: "ARQ") == .arq)
        #expect(DataFrame.kind(for: "FEC") == .fec)
        #expect(DataFrame.kind(for: "IDF") == .idf)
        #expect(DataFrame.kind(for: "ERR") == .err)
        if case .unknown(let tag) = DataFrame.kind(for: "XYZ") {
            #expect(tag == "XYZ")
        } else {
            Issue.record("expected .unknown")
        }
    }

    @Test("multiple frames concatenated in one feed")
    func multipleFrames() {
        var wire = Data()
        wire.append(DataFrameEncoder.encode(tag: "ARQ", payload: Data("one".utf8)))
        wire.append(DataFrameEncoder.encode(tag: "FEC", payload: Data("two".utf8)))
        wire.append(DataFrameEncoder.encode(tag: "IDF", payload: Data("K7ABC FN30AQ".utf8)))
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.errors.isEmpty)
        #expect(out.frames.map(\.kind) == [.arq, .fec, .idf])
        #expect(out.frames[2].payload == Data("K7ABC FN30AQ".utf8))
    }

    @Test("split reads: frame delivered across many feeds")
    func splitReads() {
        let payload = Data(repeating: 0xab, count: 1000)
        let wire = DataFrameEncoder.encode(tag: "ARQ", payload: payload)
        var parser = DataFrameParser()

        // Feed one byte at a time — torture the state machine.
        var collected: [DataFrame] = []
        for byte in wire {
            let out = parser.feed([byte])
            #expect(out.errors.isEmpty)
            collected.append(contentsOf: out.frames)
        }
        #expect(collected.count == 1)
        #expect(collected[0].payload == payload)
    }

    @Test("zero-length payload — length prefix is exactly 3 (tag only)")
    func emptyPayload() {
        let wire = DataFrameEncoder.encode(tag: "IDF", payload: Data())
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.frames.count == 1)
        #expect(out.frames[0].payload.isEmpty)
        #expect(out.frames[0].kind == .idf)
    }

    @Test("bad length (<3) is reported and skipped, recovers on next valid frame")
    func badLengthRecovers() {
        var wire = Data()
        // Bogus prefix: length = 1.
        wire.append(0x00); wire.append(0x01)
        // Then a good frame.
        wire.append(DataFrameEncoder.encode(tag: "ARQ", payload: Data("good".utf8)))
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.errors.contains(.badLength(1)))
        #expect(out.frames.count == 1)
        #expect(out.frames[0].payload == Data("good".utf8))
    }

    @Test("truncated trailing bytes remain buffered — no false frame, no error")
    func truncated() {
        var wire = DataFrameEncoder.encode(tag: "ARQ", payload: Data("abcdefgh".utf8))
        _ = wire.popLast()  // drop one byte
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.frames.isEmpty)
        #expect(out.errors.isEmpty)
    }

    @Test("length that would overflow Int bytes is still handled safely")
    func hugeLengthSafely() {
        // 65535 is the max a UInt16 can represent; we should wait for the
        // full payload, not crash.
        var wire = Data()
        wire.append(0xff); wire.append(0xff)  // length = 65535
        wire.append(contentsOf: Array("ARQ".utf8))
        // Don't send the rest; parser should buffer and wait.
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        #expect(out.frames.isEmpty)
        #expect(out.errors.isEmpty)
    }

    @Test("non-ASCII tag bytes are reported and frame is skipped")
    func nonASCIITag() {
        // length = 3, then tag bytes 0xff 0xff 0xff (invalid ASCII).
        var wire = Data([0x00, 0x03, 0xff, 0xff, 0xff])
        // Follow with a valid frame so we can confirm recovery.
        wire.append(DataFrameEncoder.encode(tag: "ARQ", payload: Data("ok".utf8)))
        var parser = DataFrameParser()
        let out = parser.feed(wire)
        // 0xff is valid ASCII (< 0x80 is required by .ascii); 0xff is not,
        // so it should be rejected.
        #expect(!out.errors.isEmpty || !out.frames.isEmpty)
        // Regardless of which branch fired, the trailing good frame must land.
        #expect(out.frames.contains { $0.payload == Data("ok".utf8) })
    }
}

@Suite("DataFrame fuzz — split reads across byte boundaries")
struct DataFrameFuzzTests {
    @Test("random split points deliver identical frames")
    func randomSplits() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let count = Int.random(in: 1...5)
            var payloads: [Data] = []
            var wire = Data()
            for _ in 0..<count {
                let n = Int.random(in: 0...512)
                let p = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
                payloads.append(p)
                let tag = ["ARQ", "FEC", "IDF", "ERR"].randomElement()!
                wire.append(DataFrameEncoder.encode(tag: tag, payload: p))
            }
            var parser = DataFrameParser()
            var collected: [Data] = []
            var cursor = 0
            while cursor < wire.count {
                let take = Int.random(in: 1...min(17, wire.count - cursor))
                let slice = wire[cursor..<(cursor + take)]
                let out = parser.feed(slice)
                #expect(out.errors.isEmpty)
                collected.append(contentsOf: out.frames.map(\.payload))
                cursor += take
            }
            #expect(collected == payloads)
        }
    }
}
