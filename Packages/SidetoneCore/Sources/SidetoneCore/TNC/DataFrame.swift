import Foundation

/// A decoded frame from the ardopcf data port.
///
/// The SPEC in this repo describes the wire format as `[2-byte BE length]
/// [4-byte type tag] [payload]`. `ardopcf`'s actual implementation (see
/// `TCPHostInterface.c::TCPAddTagToDataAndSendToHost`) uses a **3-byte** tag,
/// and the length field counts tag + payload. We code against the real
/// behavior and note the delta in `docs/protocol-notes.md`.
public struct DataFrame: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case arq
        case fec
        case idf
        case err
        /// Any 3-byte tag the TNC emits that we don't yet recognize — the raw
        /// bytes are preserved so we can surface it in diagnostics rather
        /// than drop the frame.
        case unknown(String)
    }

    public let kind: Kind
    public let rawTag: String
    public let payload: Data

    public init(kind: Kind, rawTag: String, payload: Data) {
        self.kind = kind
        self.rawTag = rawTag
        self.payload = payload
    }

    public static func kind(for tag: String) -> Kind {
        switch tag {
        case "ARQ": return .arq
        case "FEC": return .fec
        case "IDF": return .idf
        case "ERR": return .err
        default:    return .unknown(tag)
        }
    }
}

/// Incremental parser for the ardopcf data port.
///
/// Buffers partial reads across TCP packet boundaries and emits frames as
/// each is completed. Bogus length prefixes (length < 3, which would make
/// tag-decoding impossible) surface as `ParseError.badLength` — we do not
/// try to heuristically resynchronize because the stream is explicitly
/// length-prefixed and any desync means the session state is already lost.
public struct DataFrameParser: Sendable {
    public enum ParseError: Error, Equatable, Sendable {
        case badLength(UInt16)
        case invalidTagBytes
    }

    public struct Output: Sendable {
        public var frames: [DataFrame] = []
        public var errors: [ParseError] = []
    }

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> Output {
        buffer.append(contentsOf: bytes)
        var out = Output()

        while true {
            guard buffer.count >= 2 else { return out }
            let length = (UInt16(buffer[0]) << 8) | UInt16(buffer[1])

            // Length must cover the 3-byte tag.
            guard length >= 3 else {
                out.errors.append(.badLength(length))
                // Drop the bad prefix so subsequent well-formed bytes can
                // still parse. This is best-effort — if we're really
                // desynced the caller should reopen the socket.
                buffer.removeFirst(2)
                continue
            }

            let totalNeeded = 2 + Int(length)
            guard buffer.count >= totalNeeded else { return out }

            let tagBytes = Array(buffer[2..<5])
            guard let tag = String(bytes: tagBytes, encoding: .ascii),
                  tag.count == 3 else {
                out.errors.append(.invalidTagBytes)
                buffer.removeFirst(totalNeeded)
                continue
            }

            let payload = Data(buffer[5..<totalNeeded])
            out.frames.append(DataFrame(kind: DataFrame.kind(for: tag), rawTag: tag, payload: payload))
            buffer.removeFirst(totalNeeded)
        }
    }
}

/// Helper that produces a complete on-wire frame (length-prefix + tag +
/// payload) — useful for the mock TNC server and for any path in the future
/// that needs to inject synthetic frames for testing.
public enum DataFrameEncoder {
    public static func encode(tag: String, payload: Data) -> Data {
        precondition(tag.count == 3, "ardopcf data-port tags are 3 bytes")
        let tagBytes = Array(tag.utf8)
        let length = UInt16(3 + payload.count)
        var out = Data()
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xff))
        out.append(contentsOf: tagBytes)
        out.append(payload)
        return out
    }
}
