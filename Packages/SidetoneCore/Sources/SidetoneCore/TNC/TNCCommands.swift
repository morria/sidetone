import Foundation

/// ARQ bandwidth selection per the ARQBW command.
///
/// The spec accepts four widths with an optional "MAX" (negotiable) or "FORCED"
/// (non-negotiable) modifier. We model both. `forced: false` means MAX.
public enum ARQBandwidth: Sendable, Equatable {
    case hz200(forced: Bool)
    case hz500(forced: Bool)
    case hz1000(forced: Bool)
    case hz2000(forced: Bool)

    public var wireValue: String {
        switch self {
        case .hz200(let forced):  return "200" + (forced ? "FORCED" : "MAX")
        case .hz500(let forced):  return "500" + (forced ? "FORCED" : "MAX")
        case .hz1000(let forced): return "1000" + (forced ? "FORCED" : "MAX")
        case .hz2000(let forced): return "2000" + (forced ? "FORCED" : "MAX")
        }
    }
}

/// Commands the host sends to ardopcf over the command socket.
///
/// Carriage-return termination is applied by `TNCCommand.wireLine`, not by
/// callers. Commands are always uppercase on the wire even though the TNC
/// accepts mixed case — this makes on-wire transcripts easier to read in
/// replay fixtures.
public enum TNCCommand: Sendable, Equatable {
    case initialize
    case myCall(Callsign)
    case gridSquare(Grid)
    case arqBandwidth(ARQBandwidth)
    case arqCall(Callsign, repeats: Int)
    case listen(Bool)
    case disconnect
    case abort
    case sendID
    case cwID(Bool)
    case ping(Callsign, repeats: Int)
    case busyDetect(Bool)
    case autoBreak(Bool)
    case protocolMode(String)

    /// Serialize to the exact bytes that go on the wire, including the
    /// trailing `\r`. Always ASCII.
    public func wireLine() -> String {
        body + "\r"
    }

    var body: String {
        switch self {
        case .initialize:                        return "INITIALIZE"
        case .myCall(let call):                  return "MYCALL \(call.value)"
        case .gridSquare(let grid):              return "GRIDSQUARE \(grid.value)"
        case .arqBandwidth(let bw):              return "ARQBW \(bw.wireValue)"
        case .arqCall(let call, let repeats):    return "ARQCALL \(call.value) \(repeats)"
        case .listen(let on):                    return "LISTEN \(on ? "TRUE" : "FALSE")"
        case .disconnect:                        return "DISCONNECT"
        case .abort:                             return "ABORT"
        case .sendID:                            return "SENDID"
        case .cwID(let on):                      return "CWID \(on ? "TRUE" : "FALSE")"
        case .ping(let call, let repeats):       return "PING \(call.value) \(repeats)"
        case .busyDetect(let on):                return "BUSYDET \(on ? "TRUE" : "FALSE")"
        case .autoBreak(let on):                 return "AUTOBREAK \(on ? "TRUE" : "FALSE")"
        case .protocolMode(let mode):            return "PROTOCOLMODE \(mode.uppercased())"
        }
    }
}
