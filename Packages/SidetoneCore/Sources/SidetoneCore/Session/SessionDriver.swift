import Foundation

/// High-level operations the UI needs from *something* capable of running an
/// ARDOP session. Both `LocalDriver` (a local `TNCClient`+`rigctld`) and the
/// future `RemoteDriver` (WebSocket to a Sidetone server) conform. The UI
/// layer never branches on which one is live.
///
/// Drivers are actors. Callers await method completion; observable state
/// flows out through the `events` `AsyncStream`.
public protocol SessionDriver: Actor {
    /// Current session state, updated in lockstep with emitted events.
    var sessionState: SessionState { get }

    /// Stream of driver-level events, consumed by `AppState`. This is the
    /// UI-shaped version of the protocol events — not every TNC line
    /// surfaces here, only things the UI cares about.
    nonisolated var events: AsyncStream<SessionEvent> { get }

    func connect() async throws
    func initiateCall(to peer: Callsign, bandwidth: ARQBandwidth, repeats: Int) async throws
    func sendText(_ body: String) async throws
    func sendFile(data: Data, filename: String, mimeType: String) async throws
    func ping(_ peer: Callsign, repeats: Int) async throws
    func setListen(_ enabled: Bool) async throws
    func hangup(graceful: Bool) async throws
    func shutdown() async
}

/// Events the UI (via `AppState`) listens for. Distinct from `TNCEvent` —
/// a driver may aggregate or translate. For example, a remote driver might
/// coalesce several low-level transitions into a single "connected" event.
public enum SessionEvent: Sendable, Equatable {
    case stateChanged(SessionState)
    case messageReceived(Message)
    case messageSent(Message)
    case linkQuality(snr: Int, quality: Int)
    case busy(Bool)
    case ptt(Bool)
    case buffer(Int)
    case fault(String)
    case heard(Callsign, grid: Grid?)
    /// File-transfer progress update. `FileTransfer.isComplete` tells
    /// the consumer whether payload is final.
    case fileProgress(FileTransfer)
    /// A fully-reassembled inbound file; the payload data is attached.
    /// Emitted exactly once per transfer after all chunks arrive.
    case fileReceived(FileTransfer, payload: Data)
}
