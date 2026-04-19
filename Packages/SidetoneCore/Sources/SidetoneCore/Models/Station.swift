import Foundation

public struct Station: Hashable, Sendable, Codable, Identifiable {
    public var id: Callsign { callsign }
    public let callsign: Callsign
    public var grid: Grid?
    public var notes: String
    public var lastHeard: Date?

    public init(callsign: Callsign, grid: Grid? = nil, notes: String = "", lastHeard: Date? = nil) {
        self.callsign = callsign
        self.grid = grid
        self.notes = notes
        self.lastHeard = lastHeard
    }
}

public struct Message: Hashable, Sendable, Codable, Identifiable {
    public enum Direction: String, Sendable, Codable { case sent, received, system }

    public let id: UUID
    public let timestamp: Date
    public let direction: Direction
    public let peer: Callsign
    public let body: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), direction: Direction, peer: Callsign, body: String) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.peer = peer
        self.body = body
    }
}

public enum SessionState: Equatable, Sendable {
    case disconnected
    case listening
    case connecting(to: Callsign, startedAt: Date)
    case connected(peer: Callsign, bandwidth: Int, since: Date)
    case disconnecting
    case error(String)
}
