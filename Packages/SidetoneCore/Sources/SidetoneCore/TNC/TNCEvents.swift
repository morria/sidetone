import Foundation

/// Events and responses received from ardopcf on the command socket.
///
/// ardopcf uses the same socket for command responses ("MYCALL now K7CALL")
/// and asynchronous events ("NEWSTATE IRS"). We unify both into one stream so
/// callers don't need to correlate. Unknown lines surface as `.unparsed` —
/// `ardopcf` gains tags over time and we don't want to drop data silently.
public enum TNCEvent: Sendable, Equatable {
    case state(String)
    case newState(String)
    case buffer(Int)
    case connected(peer: Callsign, bandwidth: Int)
    case disconnected
    case target(Callsign)
    case ptt(Bool)
    case busy(Bool)
    case pingAck(snr: Int, quality: Int)
    case ping(from: Callsign, to: Callsign, snr: Int, quality: Int)
    case pending
    case cancelPending
    case rejectedBW(Callsign)
    case rejectedBusy(Callsign)
    case fault(String)
    case status(String)
    case pingReply
    case ack(keyword: String, body: String)
    case unparsed(String)
}

/// Parses a single ASCII line (sans trailing CR/LF) into a `TNCEvent`.
///
/// The parser is intentionally lenient: ardopcf's HostInterfaceCommands.md
/// itself notes the list is incomplete, and the project's protocol notes
/// document the delta. Any keyword we don't recognize becomes `.ack(keyword,
/// body)` (if it has trailing text) or `.unparsed(line)` (if completely
/// unknown) — never a thrown error.
public enum TNCEventParser {
    public static func parse(_ line: String) -> TNCEvent {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\t ").union(.whitespaces))
        guard !trimmed.isEmpty else { return .unparsed("") }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let keyword = tokens[0].uppercased()
        let rest = tokens.dropFirst().map { $0 }
        let tail = rest.joined(separator: " ")

        switch keyword {
        case "NEWSTATE":
            return .newState(tail)
        case "STATE":
            return .state(tail)
        case "BUFFER":
            if let n = rest.first.flatMap(Int.init) { return .buffer(n) }
            return .unparsed(trimmed)
        case "CONNECTED":
            // "CONNECTED <callsign> <bandwidth>"
            if rest.count >= 2, let call = Callsign(rest[0]), let bw = Int(rest[1]) {
                return .connected(peer: call, bandwidth: bw)
            }
            return .unparsed(trimmed)
        case "DISCONNECTED":
            return .disconnected
        case "TARGET":
            if let first = rest.first, let call = Callsign(first) { return .target(call) }
            return .unparsed(trimmed)
        case "PTT":
            return .ptt(parseBool(rest.first))
        case "BUSY":
            return .busy(parseBool(rest.first))
        case "PINGACK":
            // "PINGACK <snr> <quality>" — values may be signed ints
            if let snr = rest.first.flatMap(Int.init), let q = rest.dropFirst().first.flatMap(Int.init) {
                return .pingAck(snr: snr, quality: q)
            }
            return .unparsed(trimmed)
        case "PING":
            // "PING <caller>>[target] <snr> <quality>" per docs — the caller>target
            // segment appears as a single token "K7ABC>W1XYZ".
            if rest.count >= 3,
               let arrow = rest[0].firstIndex(of: ">") {
                let from = String(rest[0][..<arrow])
                let to = String(rest[0][rest[0].index(after: arrow)...])
                if let f = Callsign(from), let t = Callsign(to),
                   let snr = Int(rest[1]), let q = Int(rest[2]) {
                    return .ping(from: f, to: t, snr: snr, quality: q)
                }
            }
            return .unparsed(trimmed)
        case "PENDING":
            return .pending
        case "CANCELPENDING":
            return .cancelPending
        case "REJECTEDBW":
            if let first = rest.first, let call = Callsign(first) { return .rejectedBW(call) }
            return .unparsed(trimmed)
        case "REJECTEDBUSY":
            if let first = rest.first, let call = Callsign(first) { return .rejectedBusy(call) }
            return .unparsed(trimmed)
        case "FAULT":
            return .fault(tail)
        case "STATUS":
            return .status(tail)
        case "PINGREPLY":
            return .pingReply
        default:
            // "MYCALL now K7CALL" / "GRIDSQUARE now FN30AQ" — set-echo. "MYCALL K7CALL"
            // — query response. Both land here; callers correlate on keyword.
            return .ack(keyword: keyword, body: tail)
        }
    }

    private static func parseBool(_ token: String?) -> Bool {
        guard let t = token?.uppercased() else { return false }
        return t == "TRUE" || t == "1" || t == "ON"
    }
}

/// Splits an incoming byte stream into ASCII lines on `\r` (ardopcf uses CR,
/// not LF). Handles split reads across packet boundaries — the parser holds
/// partial lines between calls to `feed`.
public struct LineAccumulator: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0d || byte == 0x0a {
                if !buffer.isEmpty {
                    if let s = String(bytes: buffer, encoding: .utf8) {
                        lines.append(s)
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }
}
