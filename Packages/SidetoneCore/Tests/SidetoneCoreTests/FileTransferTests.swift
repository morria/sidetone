import Foundation
import Testing
@testable import SidetoneCore

@Suite("FileChunk — round trip")
struct FileChunkTests {
    @Test("encode + decode a single chunk round-trips all fields")
    func singleChunkRoundTrip() throws {
        let chunk = FileChunk(
            id: UUID(),
            seq: 3,
            total: 10,
            totalBytes: 9000,
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            payload: Data((0..<512).map { UInt8($0 % 256) })
        )
        let bytes = FileChunkEncoder.encode(chunk)
        let (decoded, consumed) = try FileChunkDecoder.decode(bytes)
        #expect(decoded == chunk)
        #expect(consumed == bytes.count)
    }

    @Test("decode bails on bad magic")
    func badMagic() {
        let bytes = Data([0x00, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 40))
        #expect(throws: FileChunkDecoder.DecodeError.badMagic) {
            _ = try FileChunkDecoder.decode(bytes)
        }
    }

    @Test("decode bails on unknown version")
    func badVersion() {
        var bytes = Data(FileChunk.magic)
        bytes.append(99)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 40))
        #expect(throws: (any Error).self) {
            _ = try FileChunkDecoder.decode(bytes)
        }
    }

    @Test("decode surfaces tooShort when the buffer is incomplete")
    func truncated() {
        let chunk = FileChunk(
            id: UUID(), seq: 0, total: 1, totalBytes: 10,
            filename: "x", mimeType: "text/plain", payload: Data("abcdefghij".utf8)
        )
        let full = FileChunkEncoder.encode(chunk)
        let truncated = full.prefix(full.count - 5)
        #expect(throws: FileChunkDecoder.DecodeError.tooShort) {
            _ = try FileChunkDecoder.decode(truncated)
        }
    }
}

@Suite("FileChunker + FileReassembler")
struct FileChunkerTests {
    @Test("chunker splits and reassembler rebuilds the original payload")
    func roundTrip() {
        let payload = Data((0..<5000).map { UInt8($0 & 0xff) })
        let chunks = FileChunker.chunk(
            payload,
            filename: "blob.bin",
            mimeType: "application/octet-stream",
            chunkPayloadSize: 512
        )
        #expect(chunks.count == Int(ceil(5000.0 / 512.0)))

        guard let first = chunks.first else {
            Issue.record("no chunks produced"); return
        }
        var assembler = FileReassembler(first: first)
        for chunk in chunks.dropFirst() {
            _ = assembler.accept(chunk)
        }
        #expect(assembler.isComplete)
        #expect(assembler.assembled() == payload)
    }

    @Test("out-of-order delivery still reassembles correctly")
    func outOfOrder() {
        let payload = Data((0..<1024).map { UInt8($0 & 0xff) })
        let chunks = FileChunker.chunk(payload, filename: "x", mimeType: "text/plain", chunkPayloadSize: 100)
        let shuffled = chunks.shuffled()
        var assembler = FileReassembler(first: shuffled[0])
        for chunk in shuffled.dropFirst() {
            _ = assembler.accept(chunk)
        }
        #expect(assembler.assembled() == payload)
    }

    @Test("missingChunks reflects gaps for resume")
    func missingChunks() {
        let payload = Data((0..<300).map { UInt8($0 & 0xff) })
        let chunks = FileChunker.chunk(payload, filename: "x", mimeType: "text/plain", chunkPayloadSize: 100)
        var assembler = FileReassembler(first: chunks[0])
        _ = assembler.accept(chunks[2])
        #expect(assembler.missingChunks == [1])
        _ = assembler.accept(chunks[1])
        #expect(assembler.missingChunks.isEmpty)
    }

    @Test("empty payload still yields a single chunk so the metadata lands")
    func emptyPayload() {
        let chunks = FileChunker.chunk(
            Data(), filename: "empty.txt", mimeType: "text/plain"
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].payload.isEmpty)
    }

    @Test("accept rejects a foreign id")
    func acceptWrongId() {
        let a = FileChunk(id: UUID(), seq: 0, total: 2, totalBytes: 10,
                          filename: "a", mimeType: "text/plain", payload: Data("xx".utf8))
        let b = FileChunk(id: UUID(), seq: 1, total: 2, totalBytes: 10,
                          filename: "a", mimeType: "text/plain", payload: Data("yy".utf8))
        var assembler = FileReassembler(first: a)
        #expect(assembler.accept(b) == false)
    }
}

@Suite("FileTransfer model")
struct FileTransferModelTests {
    @Test("progress and isComplete track chunksCompleted")
    func progress() {
        var transfer = FileTransfer(
            filename: "a",
            mimeType: "text/plain",
            totalBytes: 100,
            totalChunks: 4,
            direction: .inbound,
            peer: Callsign("W1ABC")!
        )
        #expect(transfer.progress == 0)
        transfer.chunksCompleted = [0, 1]
        #expect(transfer.progress == 0.5)
        #expect(transfer.isComplete == false)
        transfer.chunksCompleted = [0, 1, 2, 3]
        #expect(transfer.isComplete)
        #expect(transfer.progress == 1)
    }
}
