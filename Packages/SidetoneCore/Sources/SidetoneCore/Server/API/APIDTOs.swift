import Foundation

/// Wire-format types shared between the Sidetone server (Mac/Pi) and
/// the Sidetone client (iOS/iPad, or Mac in remote mode).
///
/// This is effectively a public contract once iOS clients ship per SPEC
/// §Deliverables, so changes to these types must be additive or versioned.
/// `/api/v1/*` is the current path; a future `/api/v2/*` can live
/// alongside.
public enum APIv1 {
    // MARK: - Core value types

    public struct StationDTO: Codable, Hashable, Sendable {
        public let callsign: String
        public let grid: String?
        public let notes: String
        public let lastHeard: Date?

        public init(callsign: String, grid: String? = nil, notes: String = "", lastHeard: Date? = nil) {
            self.callsign = callsign
            self.grid = grid
            self.notes = notes
            self.lastHeard = lastHeard
        }

        public init(_ station: Station) {
            self.callsign = station.callsign.value
            self.grid = station.grid?.value
            self.notes = station.notes
            self.lastHeard = station.lastHeard
        }

        public var asValue: Station? {
            guard let call = Callsign(callsign) else { return nil }
            return Station(
                callsign: call,
                grid: grid.flatMap(Grid.init),
                notes: notes,
                lastHeard: lastHeard
            )
        }
    }

    public struct MessageDTO: Codable, Hashable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let direction: String
        public let peer: String
        public let body: String

        public init(id: UUID, timestamp: Date, direction: String, peer: String, body: String) {
            self.id = id
            self.timestamp = timestamp
            self.direction = direction
            self.peer = peer
            self.body = body
        }

        public init(_ message: Message) {
            self.id = message.id
            self.timestamp = message.timestamp
            self.direction = message.direction.rawValue
            self.peer = message.peer.value
            self.body = message.body
        }

        public var asValue: Message? {
            guard let call = Callsign(peer),
                  let dir = Message.Direction(rawValue: direction) else { return nil }
            return Message(id: id, timestamp: timestamp, direction: dir, peer: call, body: body)
        }
    }

    public struct SessionStateDTO: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case disconnected, listening, connecting, connected, disconnecting, error
        }

        public let kind: Kind
        public let peer: String?
        public let bandwidth: Int?
        public let startedAt: Date?
        public let since: Date?
        public let reason: String?

        public init(_ state: SessionState) {
            switch state {
            case .disconnected:
                kind = .disconnected
                peer = nil; bandwidth = nil; startedAt = nil; since = nil; reason = nil
            case .listening:
                kind = .listening
                peer = nil; bandwidth = nil; startedAt = nil; since = nil; reason = nil
            case .connecting(let to, let started):
                kind = .connecting
                peer = to.value; bandwidth = nil; startedAt = started; since = nil; reason = nil
            case .connected(let p, let bw, let since):
                kind = .connected
                peer = p.value; bandwidth = bw; startedAt = nil; self.since = since; reason = nil
            case .disconnecting:
                kind = .disconnecting
                peer = nil; bandwidth = nil; startedAt = nil; since = nil; reason = nil
            case .error(let reason):
                kind = .error
                peer = nil; bandwidth = nil; startedAt = nil; since = nil; self.reason = reason
            }
        }

        public init(
            kind: Kind,
            peer: String? = nil,
            bandwidth: Int? = nil,
            startedAt: Date? = nil,
            since: Date? = nil,
            reason: String? = nil
        ) {
            self.kind = kind
            self.peer = peer
            self.bandwidth = bandwidth
            self.startedAt = startedAt
            self.since = since
            self.reason = reason
        }

        public var asValue: SessionState {
            switch kind {
            case .disconnected: return .disconnected
            case .listening: return .listening
            case .connecting:
                guard let peer, let call = Callsign(peer) else { return .disconnected }
                return .connecting(to: call, startedAt: startedAt ?? Date())
            case .connected:
                guard let peer, let call = Callsign(peer) else { return .disconnected }
                return .connected(peer: call, bandwidth: bandwidth ?? 500, since: since ?? Date())
            case .disconnecting: return .disconnecting
            case .error: return .error(reason ?? "unknown")
            }
        }
    }

    // MARK: - REST request/response

    public struct StatusResponse: Codable, Sendable {
        public let session: SessionStateDTO
        public let tncConnected: Bool
        public let rigConnected: Bool
        public let myCall: String?
        public let myGrid: String?

        public init(session: SessionStateDTO, tncConnected: Bool, rigConnected: Bool, myCall: String?, myGrid: String?) {
            self.session = session
            self.tncConnected = tncConnected
            self.rigConnected = rigConnected
            self.myCall = myCall
            self.myGrid = myGrid
        }
    }

    public struct StationsResponse: Codable, Sendable {
        public let stations: [StationDTO]
        public init(stations: [StationDTO]) { self.stations = stations }
    }

    public struct MessagesResponse: Codable, Sendable {
        public let messages: [MessageDTO]
        public init(messages: [MessageDTO]) { self.messages = messages }
    }

    public struct ConnectRequest: Codable, Sendable {
        public let callsign: String
        public let bandwidth: String?
        public let repeats: Int?
        public init(callsign: String, bandwidth: String? = nil, repeats: Int? = nil) {
            self.callsign = callsign
            self.bandwidth = bandwidth
            self.repeats = repeats
        }
    }

    public struct MessageRequest: Codable, Sendable {
        public let peer: String
        public let body: String
        public init(peer: String, body: String) {
            self.peer = peer
            self.body = body
        }
    }

    public struct ListenRequest: Codable, Sendable {
        public let enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    public struct FrequencyRequest: Codable, Sendable {
        public let hz: Int
        public init(hz: Int) { self.hz = hz }
    }

    public struct PairRequest: Codable, Sendable {
        public let code: String
        public let deviceName: String
        public init(code: String, deviceName: String) {
            self.code = code
            self.deviceName = deviceName
        }
    }

    public struct PairResponse: Codable, Sendable {
        public let token: String
        public let certificateFingerprint: String
        public let serverName: String
        public init(token: String, certificateFingerprint: String, serverName: String) {
            self.token = token
            self.certificateFingerprint = certificateFingerprint
            self.serverName = serverName
        }
    }

    public struct ErrorResponse: Codable, Sendable {
        public let code: String
        public let message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: - WebSocket event envelope

    /// Discriminated envelope carrying any server → client push event.
    /// Encoded with a `kind` tag so extending the enum is backward
    /// compatible — clients skip unknown kinds rather than failing.
    public struct EventEnvelope: Codable, Sendable {
        public let kind: String
        public let data: AnyCodable

        public init(kind: String, data: AnyCodable) {
            self.kind = kind
            self.data = data
        }

        public init<T: Encodable>(kind: String, payload: T) throws {
            self.kind = kind
            self.data = try AnyCodable(encoding: payload)
        }
    }

    public struct LinkQualityEvent: Codable, Sendable {
        public let snr: Int
        public let quality: Int
        public init(snr: Int, quality: Int) { self.snr = snr; self.quality = quality }
    }

    public struct BoolEvent: Codable, Sendable {
        public let value: Bool
        public init(_ value: Bool) { self.value = value }
    }

    public struct IntEvent: Codable, Sendable {
        public let value: Int
        public init(_ value: Int) { self.value = value }
    }

    public struct FaultEvent: Codable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Canonical event-kind strings. The server emits these; clients
    /// branch on them. New kinds are additive — never rename without
    /// bumping the API path.
    public enum EventKind {
        public static let stateChanged = "state_changed"
        public static let messageReceived = "message_received"
        public static let messageSent = "message_sent"
        public static let linkQuality = "link_quality"
        public static let ptt = "ptt"
        public static let busy = "busy"
        public static let buffer = "buffer"
        public static let fault = "fault"
        public static let heard = "heard"
        public static let fileProgress = "file_progress"
        public static let fileReceived = "file_received"
    }

    /// Wire-level view of an in-progress transfer. The payload itself
    /// is intentionally out of band — completed files go through a
    /// separate HTTP download endpoint (TBD M10c) keyed by the id.
    /// That keeps the event stream small and preserves JSON-friendliness.
    public struct FileTransferDTO: Codable, Hashable, Sendable {
        public let id: UUID
        public let filename: String
        public let mimeType: String
        public let totalBytes: Int
        public let totalChunks: Int
        public let direction: String
        public let peer: String
        public let chunksCompleted: Int
        public let isComplete: Bool
        public init(
            id: UUID,
            filename: String,
            mimeType: String,
            totalBytes: Int,
            totalChunks: Int,
            direction: String,
            peer: String,
            chunksCompleted: Int,
            isComplete: Bool
        ) {
            self.id = id
            self.filename = filename
            self.mimeType = mimeType
            self.totalBytes = totalBytes
            self.totalChunks = totalChunks
            self.direction = direction
            self.peer = peer
            self.chunksCompleted = chunksCompleted
            self.isComplete = isComplete
        }

        public init(_ transfer: FileTransfer) {
            self.id = transfer.id
            self.filename = transfer.filename
            self.mimeType = transfer.mimeType
            self.totalBytes = transfer.totalBytes
            self.totalChunks = transfer.totalChunks
            self.direction = transfer.direction.rawValue
            self.peer = transfer.peer.value
            self.chunksCompleted = transfer.chunksCompleted.count
            self.isComplete = transfer.isComplete
        }
    }
}

/// Type-erased JSON payload inside an envelope. Carries any valid JSON
/// value so older clients can parse and skip unknown event payloads
/// instead of failing.
///
/// Construct with `AnyCodable(encoding: someCodable)` at the producing
/// end; decode with `payload.decode(as: SomePayload.self)` at the
/// consumer.
public enum AnyCodable: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(EncodingBox(value))
        self = try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyCodable].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnyCodable].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Decode the wrapped JSON as a specific Codable type. Slightly
    /// wasteful (re-encodes then decodes) but correct for any payload.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Private box so we can pass `any Encodable` through the generic
/// `<T: Encodable>` slot on JSONEncoder.encode.
private struct EncodingBox<T: Encodable>: Encodable {
    let value: T
    init(_ value: T) { self.value = value }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
