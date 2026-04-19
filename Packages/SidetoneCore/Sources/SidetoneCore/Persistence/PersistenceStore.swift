import Foundation
import SwiftData

/// CRUD facade around SwiftData's `ModelContext`.
///
/// SwiftData's contexts are not `Sendable` and must be used from a single
/// concurrent actor. We pin this store to the `@MainActor` because every
/// caller (AppState, SwiftUI views) already runs there — hopping off-main
/// just to persist a single message would introduce a cache-coherence
/// problem for no benefit.
///
/// For production the app creates one of these at launch with the default
/// on-disk configuration. Tests construct with `.inMemory()` so they don't
/// leak state across runs.
@MainActor
public final class PersistenceStore {
    public enum Configuration {
        case onDisk(URL)
        case inMemory
        case defaultApplicationSupport
    }

    public enum StoreError: Error, Sendable {
        case setup(String)
    }

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(_ configuration: Configuration = .defaultApplicationSupport) throws {
        let schema = Schema([PersistedStation.self, PersistedMessage.self])
        do {
            switch configuration {
            case .onDisk(let url):
                let config = ModelConfiguration(schema: schema, url: url)
                self.container = try ModelContainer(for: schema, configurations: config)
            case .inMemory:
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                self.container = try ModelContainer(for: schema, configurations: config)
            case .defaultApplicationSupport:
                self.container = try ModelContainer(for: schema)
            }
        } catch {
            throw StoreError.setup(error.localizedDescription)
        }
    }

    // MARK: - Stations

    public func allStations() throws -> [Station] {
        let descriptor = FetchDescriptor<PersistedStation>(
            sortBy: [SortDescriptor(\.callsign)]
        )
        return try context.fetch(descriptor).compactMap(\.asValue)
    }

    public func saveStation(_ station: Station) throws {
        let call = station.callsign.value
        let existing = try fetchStation(by: call)
        if let existing {
            existing.grid = station.grid?.value
            existing.notes = station.notes
            existing.lastHeard = station.lastHeard
        } else {
            context.insert(
                PersistedStation(
                    callsign: call,
                    grid: station.grid?.value,
                    notes: station.notes,
                    lastHeard: station.lastHeard
                )
            )
        }
        try context.save()
    }

    public func deleteStation(_ callsign: Callsign) throws {
        guard let existing = try fetchStation(by: callsign.value) else { return }
        context.delete(existing)
        try context.save()
    }

    private func fetchStation(by callsign: String) throws -> PersistedStation? {
        var descriptor = FetchDescriptor<PersistedStation>(
            predicate: #Predicate { $0.callsign == callsign }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Messages

    public func append(_ message: Message) throws {
        context.insert(
            PersistedMessage(
                id: message.id,
                timestamp: message.timestamp,
                direction: message.direction,
                peer: message.peer.value,
                body: message.body
            )
        )
        try context.save()
    }

    public func transcript(for peer: Callsign, limit: Int = 500) throws -> [Message] {
        let call = peer.value
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.peer == call },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).compactMap(\.asValue)
    }

    public func deleteTranscript(for peer: Callsign) throws {
        let call = peer.value
        try context.delete(
            model: PersistedMessage.self,
            where: #Predicate { $0.peer == call }
        )
        try context.save()
    }
}
