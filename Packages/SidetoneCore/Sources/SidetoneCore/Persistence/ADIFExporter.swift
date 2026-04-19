import Foundation

/// Exports Sidetone's message log as ADIF (Amateur Data Interchange
/// Format) — the standard text format every ham logging program
/// reads. Operators can feed the file into MacLoggerDX, N1MM, LoTW,
/// etc.
///
/// We don't persist QSOs as first-class records (yet) — instead we
/// derive them from the message history: one QSO per peer per
/// cluster of activity, with a new QSO starting when there's a gap
/// of `quietGap` between consecutive messages to the same peer.
public struct ADIFExporter: Sendable {
    public let quietGap: TimeInterval
    public let myCall: Callsign?
    public let myGrid: Grid?

    public init(
        myCall: Callsign? = nil,
        myGrid: Grid? = nil,
        quietGap: TimeInterval = 2 * 60 * 60
    ) {
        self.myCall = myCall
        self.myGrid = myGrid
        self.quietGap = quietGap
    }

    public func export(_ messages: [Message]) -> String {
        var output = ""
        appendHeader(to: &output)
        for qso in coalesce(messages) {
            appendRecord(qso, to: &output)
        }
        return output
    }

    // MARK: - QSO derivation

    struct DerivedQSO {
        let peer: Callsign
        let startedAt: Date
        let endedAt: Date
        let rxCount: Int
        let txCount: Int
    }

    func coalesce(_ messages: [Message]) -> [DerivedQSO] {
        var byPeer: [Callsign: [Message]] = [:]
        for m in messages where m.direction != .system {
            byPeer[m.peer, default: []].append(m)
        }

        var qsos: [DerivedQSO] = []
        for (peer, msgs) in byPeer {
            let sorted = msgs.sorted(by: { $0.timestamp < $1.timestamp })
            var currentStart: Date?
            var currentEnd: Date?
            var rx = 0
            var tx = 0

            func flush() {
                guard let start = currentStart, let end = currentEnd else { return }
                qsos.append(DerivedQSO(peer: peer, startedAt: start, endedAt: end, rxCount: rx, txCount: tx))
                currentStart = nil; currentEnd = nil; rx = 0; tx = 0
            }

            for message in sorted {
                if let end = currentEnd, message.timestamp.timeIntervalSince(end) > quietGap {
                    flush()
                }
                if currentStart == nil { currentStart = message.timestamp }
                currentEnd = message.timestamp
                switch message.direction {
                case .received: rx += 1
                case .sent: tx += 1
                case .system: break
                }
            }
            flush()
        }
        return qsos.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - ADIF formatting

    private func appendHeader(to output: inout String) {
        output += "Sidetone ADIF export\n"
        output += field("ADIF_VER", "3.1.5")
        output += field("PROGRAMID", "Sidetone")
        output += field("CREATED_TIMESTAMP", adifTimestamp(from: Date()))
        output += "<eoh>\n"
    }

    private func appendRecord(_ qso: DerivedQSO, to output: inout String) {
        let dateOn = adifDate(from: qso.startedAt)
        let timeOn = adifTime(from: qso.startedAt)
        let dateOff = adifDate(from: qso.endedAt)
        let timeOff = adifTime(from: qso.endedAt)

        output += field("QSO_DATE", dateOn)
        output += field("TIME_ON", timeOn)
        output += field("QSO_DATE_OFF", dateOff)
        output += field("TIME_OFF", timeOff)
        output += field("CALL", qso.peer.value)
        output += field("MODE", "ARDOP")
        if let myCall { output += field("OPERATOR", myCall.value) }
        if let myGrid { output += field("MY_GRIDSQUARE", myGrid.value) }
        output += field("COMMENT", "rx=\(qso.rxCount) tx=\(qso.txCount)")
        output += "<eor>\n"
    }

    private func field(_ name: String, _ value: String) -> String {
        // ADIF specifies length in bytes (UTF-8). Most Sidetone data is
        // ASCII but callsigns with slashes and grids sometimes aren't.
        let byteCount = value.utf8.count
        return "<\(name):\(byteCount)>\(value) "
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HHmmss"
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd HHmmss"
        return f
    }()

    private func adifDate(from date: Date) -> String { Self.dateFormatter.string(from: date) }
    private func adifTime(from date: Date) -> String { Self.timeFormatter.string(from: date) }
    private func adifTimestamp(from date: Date) -> String { Self.timestampFormatter.string(from: date) }
}
