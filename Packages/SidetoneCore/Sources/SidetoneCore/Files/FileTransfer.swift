import Foundation

/// An in-flight or completed file transfer. Tracked separately from
/// `Message` because ARDOP-ARQ byte rates mean a 200 KB image can take
/// 10+ minutes to cross the air; the UI wants to show progress, and
/// we want to resume on reconnect.
public struct FileTransfer: Hashable, Sendable, Identifiable {
    public enum Direction: String, Sendable, Codable {
        case outbound, inbound
    }

    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let totalBytes: Int
    public let totalChunks: Int
    public let direction: Direction
    public let peer: Callsign
    public var chunksCompleted: Set<Int>
    public var startedAt: Date
    public var completedAt: Date?

    public var progress: Double {
        guard totalChunks > 0 else { return 1 }
        return Double(chunksCompleted.count) / Double(totalChunks)
    }

    public var isComplete: Bool {
        chunksCompleted.count == totalChunks
    }

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        totalBytes: Int,
        totalChunks: Int,
        direction: Direction,
        peer: Callsign,
        chunksCompleted: Set<Int> = [],
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.totalChunks = totalChunks
        self.direction = direction
        self.peer = peer
        self.chunksCompleted = chunksCompleted
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
