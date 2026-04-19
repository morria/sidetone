import Foundation
import SwiftData

/// SwiftData-backed mirror of `Station`.
///
/// We keep `Station`/`Message`/etc. as plain Sendable value types so pure
/// protocol logic and tests don't need SwiftData, and have these `@Model`
/// companions for persistence. `PersistenceStore` owns the conversion in
/// both directions.
@Model
public final class PersistedStation {
    @Attribute(.unique) public var callsign: String
    public var grid: String?
    public var notes: String
    public var lastHeard: Date?

    public init(callsign: String, grid: String? = nil, notes: String = "", lastHeard: Date? = nil) {
        self.callsign = callsign
        self.grid = grid
        self.notes = notes
        self.lastHeard = lastHeard
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

@Model
public final class PersistedMessage {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var directionRaw: String
    public var peer: String
    public var body: String

    public init(id: UUID, timestamp: Date, direction: Message.Direction, peer: String, body: String) {
        self.id = id
        self.timestamp = timestamp
        self.directionRaw = direction.rawValue
        self.peer = peer
        self.body = body
    }

    public var asValue: Message? {
        guard let call = Callsign(peer),
              let dir = Message.Direction(rawValue: directionRaw) else { return nil }
        return Message(id: id, timestamp: timestamp, direction: dir, peer: call, body: body)
    }
}
