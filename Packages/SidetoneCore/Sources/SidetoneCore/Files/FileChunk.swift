import Foundation

/// On-wire framing for a single chunk of a file transfer.
///
/// Wire layout (big-endian):
/// ```
/// [ 4 bytes magic = "SIDF" ] ASCII, identifies our sub-protocol
/// [ 1 byte  version = 1    ]
/// [ 16 bytes id            ] UUID raw bytes
/// [ 4 bytes  seq           ] UInt32, 0-based
/// [ 4 bytes  total         ] UInt32, total chunks
/// [ 4 bytes  totalBytes    ] UInt32, total payload size (first chunk only, else 0)
/// [ 2 bytes  filenameLen   ] UInt16
/// [ N bytes  filename      ] UTF-8
/// [ 2 bytes  mimeLen       ] UInt16
/// [ N bytes  mimeType      ] UTF-8
/// [ 4 bytes  payloadLen    ] UInt32
/// [ N bytes  payload       ]
/// ```
///
/// The magic lets a receiver distinguish file chunks from plain text
/// messages inside the same ARQ stream. A version byte gives us room
/// to evolve without breaking old peers.
public struct FileChunk: Hashable, Sendable {
    public static let magic: [UInt8] = [0x53, 0x49, 0x44, 0x46] // "SIDF"
    public static let currentVersion: UInt8 = 1

    public let id: UUID
    public let seq: Int
    public let total: Int
    public let totalBytes: Int
    public let filename: String
    public let mimeType: String
    public let payload: Data

    public init(id: UUID, seq: Int, total: Int, totalBytes: Int, filename: String, mimeType: String, payload: Data) {
        self.id = id
        self.seq = seq
        self.total = total
        self.totalBytes = totalBytes
        self.filename = filename
        self.mimeType = mimeType
        self.payload = payload
    }
}

public enum FileChunkEncoder {
    public static func encode(_ chunk: FileChunk) -> Data {
        var out = Data()
        out.append(contentsOf: FileChunk.magic)
        out.append(FileChunk.currentVersion)
        withUnsafeBytes(of: chunk.id.uuid) { out.append(contentsOf: $0) }
        appendUInt32BE(UInt32(chunk.seq), to: &out)
        appendUInt32BE(UInt32(chunk.total), to: &out)
        appendUInt32BE(UInt32(chunk.totalBytes), to: &out)

        let filenameBytes = Data(chunk.filename.utf8)
        appendUInt16BE(UInt16(filenameBytes.count), to: &out)
        out.append(filenameBytes)

        let mimeBytes = Data(chunk.mimeType.utf8)
        appendUInt16BE(UInt16(mimeBytes.count), to: &out)
        out.append(mimeBytes)

        appendUInt32BE(UInt32(chunk.payload.count), to: &out)
        out.append(chunk.payload)
        return out
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}

public enum FileChunkDecoder {
    public enum DecodeError: Error, Equatable, Sendable {
        case tooShort
        case badMagic
        case unsupportedVersion(UInt8)
        case fieldTruncated
        case badUTF8
    }

    /// Attempt to decode a single chunk from `data`. Returns the chunk
    /// plus the number of bytes consumed. Throws `.tooShort` if more
    /// bytes are needed (caller should buffer and retry), and harder
    /// errors for malformed frames the caller should probably propagate.
    public static func decode(_ data: Data) throws -> (FileChunk, consumed: Int) {
        var cursor = 0
        func take(_ n: Int) throws -> Data {
            guard cursor + n <= data.count else { throw DecodeError.tooShort }
            let slice = data.subdata(in: cursor..<(cursor + n))
            cursor += n
            return slice
        }
        func takeU16() throws -> UInt16 {
            let d = try take(2)
            return (UInt16(d[d.startIndex]) << 8) | UInt16(d[d.startIndex + 1])
        }
        func takeU32() throws -> UInt32 {
            let d = try take(4)
            var value: UInt32 = 0
            for b in d { value = (value << 8) | UInt32(b) }
            return value
        }

        let magic = try take(4)
        guard Array(magic) == FileChunk.magic else {
            throw DecodeError.badMagic
        }
        let version = try take(1)[0]
        guard version == FileChunk.currentVersion else {
            throw DecodeError.unsupportedVersion(version)
        }
        let uuidBytes = try take(16)
        var tuple: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &tuple) { uuidBytes.copyBytes(to: $0) }
        let id = UUID(uuid: tuple)

        let seq = Int(try takeU32())
        let total = Int(try takeU32())
        let totalBytes = Int(try takeU32())

        let filenameLen = Int(try takeU16())
        let filename = String(data: try take(filenameLen), encoding: .utf8)
        guard let filename else { throw DecodeError.badUTF8 }

        let mimeLen = Int(try takeU16())
        let mime = String(data: try take(mimeLen), encoding: .utf8)
        guard let mime else { throw DecodeError.badUTF8 }

        let payloadLen = Int(try takeU32())
        let payload = try take(payloadLen)

        let chunk = FileChunk(
            id: id,
            seq: seq,
            total: total,
            totalBytes: totalBytes,
            filename: filename,
            mimeType: mime,
            payload: payload
        )
        return (chunk, cursor)
    }
}

/// Splits a payload into FileChunks sized for ARDOP.
///
/// Typical ARDOP ARQ bandwidths move 200–600 bytes per second over HF;
/// 1 KB chunks let us show progress updates every 2–5 seconds on a
/// good path without bloating the header/payload ratio too far.
public enum FileChunker {
    public static let defaultChunkPayload = 1024

    public static func chunk(
        _ data: Data,
        filename: String,
        mimeType: String,
        chunkPayloadSize: Int = defaultChunkPayload,
        id: UUID = UUID()
    ) -> [FileChunk] {
        precondition(chunkPayloadSize > 0, "chunk size must be positive")
        let total = Int(ceil(Double(data.count) / Double(chunkPayloadSize)))
        // Pathological: empty payload still produces one chunk so the
        // receiver knows the transfer happened (and the metadata is
        // carried by the header).
        let effectiveTotal = max(1, total)

        var out: [FileChunk] = []
        out.reserveCapacity(effectiveTotal)
        for seq in 0..<effectiveTotal {
            let start = seq * chunkPayloadSize
            let end = min(start + chunkPayloadSize, data.count)
            let slice = (start < end) ? data.subdata(in: start..<end) : Data()
            out.append(FileChunk(
                id: id,
                seq: seq,
                total: effectiveTotal,
                totalBytes: data.count,
                filename: filename,
                mimeType: mimeType,
                payload: slice
            ))
        }
        return out
    }
}

/// Reassembles received chunks into a complete payload. Tolerant of
/// out-of-order delivery and duplicates.
public struct FileReassembler: Sendable {
    public private(set) var chunks: [Int: FileChunk] = [:]
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let total: Int
    public let totalBytes: Int

    public init(first chunk: FileChunk) {
        self.id = chunk.id
        self.filename = chunk.filename
        self.mimeType = chunk.mimeType
        self.total = chunk.total
        self.totalBytes = chunk.totalBytes
        self.chunks[chunk.seq] = chunk
    }

    public mutating func accept(_ chunk: FileChunk) -> Bool {
        guard chunk.id == id, chunk.total == total else { return false }
        chunks[chunk.seq] = chunk
        return true
    }

    public var isComplete: Bool { chunks.count == total }

    public var missingChunks: [Int] {
        (0..<total).filter { chunks[$0] == nil }
    }

    public func assembled() -> Data? {
        guard isComplete else { return nil }
        var out = Data()
        out.reserveCapacity(totalBytes)
        for seq in 0..<total {
            if let chunk = chunks[seq] {
                out.append(chunk.payload)
            } else {
                return nil
            }
        }
        return out
    }
}
