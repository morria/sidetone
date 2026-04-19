import Foundation
import SidetoneCore

/// Server-side aggregate that the HTTP/WS layer talks to. Owns the
/// live `SessionDriver` (normally a `LocalDriver`) and a
/// `PersistenceStore`, fans driver events out to subscribed clients,
/// and exposes the intent/query surface the REST endpoints need.
///
/// Multiple clients may be subscribed at once — every WebSocket client
/// registered with `subscribe(_:)` receives every event. If we
/// eventually grow multi-operator coordination (two phones driving one
/// session), the per-client partitioning lands here.
public actor ServerHost {
    public typealias Subscriber = @Sendable (SessionEvent) -> Void

    public struct Identity: Sendable {
        public let callsign: Callsign
        public let grid: Grid?
        public init(callsign: Callsign, grid: Grid? = nil) {
            self.callsign = callsign
            self.grid = grid
        }
    }

    private let driver: any SessionDriver
    private let store: PersistenceStore?
    private let identity: Identity
    private var pumpTask: Task<Void, Never>?
    private var subscribers: [UUID: Subscriber] = [:]
    private(set) var lastState: SessionState = .disconnected
    private(set) var lastLinkQuality: (snr: Int, quality: Int)?
    private(set) var lastBuffer: Int = 0
    private(set) var ptt: Bool = false
    private(set) var busy: Bool = false
    private(set) var lastFault: String?

    public init(driver: any SessionDriver, store: PersistenceStore?, identity: Identity) {
        self.driver = driver
        self.store = store
        self.identity = identity
    }

    public func start() async {
        // AsyncStream is single-consumer. Guard against a double-start
        // race — the broadcaster calls this on first WS client, and the
        // test rig also may. Second calls are no-ops.
        guard pumpTask == nil else { return }
        let driver = self.driver
        pumpTask = Task { [weak self] in
            for await event in driver.events {
                await self?.ingest(event)
            }
        }
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        subscribers.removeAll()
    }

    // MARK: - Subscriptions

    /// Register a new event subscriber. Returns an opaque ID the caller
    /// passes to `unsubscribe` when the client disconnects.
    public func subscribe(_ handler: @escaping Subscriber) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        // Kick the new subscriber with the current state so the client
        // doesn't need a separate GET /status round-trip to render.
        handler(.stateChanged(lastState))
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Query surface

    public func snapshot() -> APIv1.StatusResponse {
        APIv1.StatusResponse(
            session: APIv1.SessionStateDTO(lastState),
            tncConnected: true,
            rigConnected: false,
            myCall: identity.callsign.value,
            myGrid: identity.grid?.value
        )
    }

    @MainActor
    public func stations(via store: PersistenceStore) throws -> [APIv1.StationDTO] {
        try store.allStations().map(APIv1.StationDTO.init)
    }

    @MainActor
    public func transcript(for peer: Callsign, via store: PersistenceStore, limit: Int = 500) throws -> [APIv1.MessageDTO] {
        try store.transcript(for: peer, limit: limit).map(APIv1.MessageDTO.init)
    }

    public var persistence: PersistenceStore? { store }

    // MARK: - Intents

    public func connect(to peer: Callsign, bandwidth: ARQBandwidth, repeats: Int) async throws {
        try await driver.initiateCall(to: peer, bandwidth: bandwidth, repeats: repeats)
    }

    public func disconnect(graceful: Bool) async throws {
        try await driver.hangup(graceful: graceful)
    }

    public func sendText(_ body: String) async throws {
        try await driver.sendText(body)
    }

    public func sendFile(data: Data, filename: String, mimeType: String) async throws {
        try await driver.sendFile(data: data, filename: filename, mimeType: mimeType)
    }

    public func setListen(_ enabled: Bool) async throws {
        try await driver.setListen(enabled)
    }

    public func ping(_ peer: Callsign, repeats: Int) async throws {
        try await driver.ping(peer, repeats: repeats)
    }

    // MARK: - Event ingestion

    private func ingest(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let s):
            lastState = s
        case .linkQuality(let snr, let q):
            lastLinkQuality = (snr, q)
        case .buffer(let n):
            lastBuffer = n
        case .ptt(let on):
            ptt = on
        case .busy(let on):
            busy = on
        case .fault(let reason):
            lastFault = reason
        case .messageSent, .messageReceived, .heard,
             .fileProgress, .fileReceived:
            break
        }
        for subscriber in subscribers.values {
            subscriber(event)
        }
    }
}
