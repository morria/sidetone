import Foundation
import Observation

/// Single source of truth for the UI. Owns the session state, the station
/// roster, and the transcript. Views read `AppState` directly; intents flow
/// back through the small set of methods here, which dispatch to the
/// underlying `SessionDriver`.
///
/// `@Observable` + `@MainActor`: SwiftUI reads property changes on the main
/// actor without Combine. Driver pumps marshal onto the main actor before
/// mutating.
@MainActor
@Observable
public final class AppState {
    public private(set) var sessionState: SessionState = .disconnected
    public private(set) var stations: [Station] = []
    public private(set) var heard: [Station] = []
    public private(set) var transcripts: [Callsign: [Message]] = [:]
    public private(set) var lastLinkQuality: (snr: Int, quality: Int)?
    public private(set) var ptt: Bool = false
    public private(set) var busy: Bool = false
    public private(set) var bufferBytes: Int = 0
    public private(set) var lastFault: String?
    public private(set) var fileTransfers: [UUID: FileTransfer] = [:]

    public var myCall: Callsign? { driver?.identity.callsign }
    public var myGrid: Grid? { driver?.identity.grid }

    private var driver: DriverHandle?
    private var pumpTask: Task<Void, Never>?
    private let store: PersistenceStore?

    public init(store: PersistenceStore? = nil) {
        self.store = store
        if let store {
            stations = (try? store.allStations()) ?? []
        }
    }

    public func attach(_ driver: any SessionDriver, identity: Identity) {
        self.driver = DriverHandle(driver: driver, identity: identity)
        pumpTask = Task { [weak self] in
            for await event in driver.events {
                self?.apply(event)
            }
        }
    }

    public func detach() async {
        pumpTask?.cancel()
        pumpTask = nil
        if let handle = driver {
            await handle.driver.shutdown()
        }
        driver = nil
    }

    public func saveStation(_ station: Station) {
        if let idx = stations.firstIndex(where: { $0.callsign == station.callsign }) {
            stations[idx] = station
        } else {
            stations.append(station)
        }
        try? store?.saveStation(station)
    }

    public func removeStation(_ callsign: Callsign) {
        stations.removeAll { $0.callsign == callsign }
        try? store?.deleteStation(callsign)
    }

    /// Reload the cached transcript for a peer from the persistence store.
    /// SwiftUI views call this when they need history predating the current
    /// session. Updates are delivered via the existing `@Observable` path.
    public func loadTranscript(for peer: Callsign, limit: Int = 500) {
        guard let store else { return }
        if let persisted = try? store.transcript(for: peer, limit: limit) {
            transcripts[peer] = persisted
        }
    }

    // MARK: - Intents

    public func connect(to peer: Callsign, bandwidth: ARQBandwidth = .hz500(forced: false), repeats: Int = 5) async throws {
        guard let handle = driver else { return }
        try await handle.driver.initiateCall(to: peer, bandwidth: bandwidth, repeats: repeats)
    }

    public func send(_ body: String) async throws {
        guard let handle = driver else { return }
        try await handle.driver.sendText(body)
    }

    public func sendFile(data: Data, filename: String, mimeType: String) async throws {
        guard let handle = driver else { return }
        try await handle.driver.sendFile(data: data, filename: filename, mimeType: mimeType)
    }

    public func ping(_ peer: Callsign, repeats: Int = 3) async throws {
        guard let handle = driver else { return }
        try await handle.driver.ping(peer, repeats: repeats)
    }

    public func toggleListen(_ enabled: Bool) async throws {
        guard let handle = driver else { return }
        try await handle.driver.setListen(enabled)
    }

    public func hangup(graceful: Bool = true) async throws {
        guard let handle = driver else { return }
        try await handle.driver.hangup(graceful: graceful)
    }

    // MARK: - Event reducer

    private func apply(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let s):
            sessionState = s
        case .messageReceived(let m):
            transcripts[m.peer, default: []].append(m)
            try? store?.append(m)
        case .messageSent(let m):
            transcripts[m.peer, default: []].append(m)
            try? store?.append(m)
        case .linkQuality(let snr, let q):
            lastLinkQuality = (snr, q)
        case .ptt(let on):
            ptt = on
        case .busy(let on):
            busy = on
        case .buffer(let n):
            bufferBytes = n
        case .fault(let reason):
            lastFault = reason
        case .heard(let call, let grid):
            let station = Station(callsign: call, grid: grid, lastHeard: Date())
            if let idx = heard.firstIndex(where: { $0.callsign == call }) {
                heard[idx] = station
            } else {
                heard.append(station)
            }
            // If the heard station is already a saved station, bump its
            // lastHeard so the station's indicator refreshes and persists.
            if let idx = stations.firstIndex(where: { $0.callsign == call }) {
                var saved = stations[idx]
                saved.lastHeard = station.lastHeard
                saved.grid = saved.grid ?? grid
                stations[idx] = saved
                try? store?.saveStation(saved)
            }
        case .fileProgress(let transfer):
            fileTransfers[transfer.id] = transfer
        case .fileReceived(let transfer, _):
            fileTransfers[transfer.id] = transfer
        }
    }

    public struct Identity: Sendable {
        public let callsign: Callsign
        public let grid: Grid?

        public init(callsign: Callsign, grid: Grid? = nil) {
            self.callsign = callsign
            self.grid = grid
        }
    }

    private struct DriverHandle {
        let driver: any SessionDriver
        let identity: Identity
    }
}
