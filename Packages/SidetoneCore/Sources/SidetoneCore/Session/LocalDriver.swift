import Foundation

/// `SessionDriver` implementation that talks to a local `ardopcf` via
/// `TNCClient`. Translates TNC-protocol events into the UI-shaped
/// `SessionEvent` stream and maintains the high-level `SessionState`.
///
/// The driver owns exactly one TNCClient. It is the only component that
/// interprets the TNC FSM — anything upstream works in terms of
/// `SessionState`.
public actor LocalDriver: SessionDriver {
    public private(set) var sessionState: SessionState = .disconnected

    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

    private let tnc: TNCClient
    private let myCall: Callsign
    private let grid: Grid?
    private var pumpTask: Task<Void, Never>?
    private var dataPumpTask: Task<Void, Never>?
    private var currentPeer: Callsign?

    public init(tnc: TNCClient, myCall: Callsign, grid: Grid?) {
        self.tnc = tnc
        self.myCall = myCall
        self.grid = grid
        (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    public func connect() async throws {
        try await tnc.connect()

        // The order here matters: INITIALIZE before identity-setting commands
        // per ardopcf's host interface. `setListen(false)` keeps the TNC
        // quiet until the UI explicitly goes to listen mode.
        try await tnc.send(.initialize)
        try await tnc.send(.myCall(myCall))
        if let grid { try await tnc.send(.gridSquare(grid)) }
        try await tnc.send(.listen(false))

        startPumps()
        updateState(.disconnected)
    }

    public func initiateCall(to peer: Callsign, bandwidth: ARQBandwidth, repeats: Int) async throws {
        try await tnc.send(.arqBandwidth(bandwidth))
        currentPeer = peer
        updateState(.connecting(to: peer, startedAt: Date()))
        try await tnc.send(.arqCall(peer, repeats: repeats))
    }

    public func sendText(_ body: String) async throws {
        guard case .connected(let peer, _, _) = sessionState else {
            throw DriverError.notInSession
        }
        // Text over ARDOP is just bytes written to the TNC's outbound buffer
        // on the command socket via the plain TCP channel. ardopcf reads
        // from that same socket and forwards to the ARQ connection. The
        // spec's host interface uses a direct write of the text — no length
        // prefix, no framing — terminated however the TNC expects (no
        // terminator is added by us here).
        try await tnc.sendRawLine(body)
        let msg = Message(direction: .sent, peer: peer, body: body)
        eventContinuation.yield(.messageSent(msg))
    }

    public func ping(_ peer: Callsign, repeats: Int) async throws {
        try await tnc.send(.ping(peer, repeats: repeats))
    }

    public func setListen(_ enabled: Bool) async throws {
        try await tnc.send(.listen(enabled))
        if enabled, case .disconnected = sessionState {
            updateState(.listening)
        }
    }

    public func hangup(graceful: Bool) async throws {
        if graceful {
            try await tnc.send(.disconnect)
        } else {
            try await tnc.send(.abort)
        }
        updateState(.disconnecting)
    }

    public func shutdown() async {
        pumpTask?.cancel()
        dataPumpTask?.cancel()
        pumpTask = nil
        dataPumpTask = nil
        await tnc.disconnect()
        updateState(.disconnected)
        eventContinuation.finish()
    }

    // MARK: - Internals

    public enum DriverError: Error, Sendable, Equatable {
        case notInSession
    }

    private func updateState(_ new: SessionState) {
        sessionState = new
        eventContinuation.yield(.stateChanged(new))
    }

    private func startPumps() {
        let tnc = self.tnc
        pumpTask = Task { [weak self] in
            for await event in tnc.events {
                guard let self else { return }
                await self.handle(tncEvent: event)
            }
        }
        dataPumpTask = Task { [weak self] in
            for await frame in tnc.frames {
                guard let self else { return }
                await self.handle(frame: frame)
            }
        }
    }

    private func handle(tncEvent: TNCEvent) {
        switch tncEvent {
        case .connected(let peer, let bw):
            currentPeer = peer
            updateState(.connected(peer: peer, bandwidth: bw, since: Date()))
        case .disconnected:
            currentPeer = nil
            updateState(.disconnected)
        case .fault(let reason):
            updateState(.error(reason))
            eventContinuation.yield(.fault(reason))
        case .ptt(let on):
            eventContinuation.yield(.ptt(on))
        case .busy(let on):
            eventContinuation.yield(.busy(on))
        case .buffer(let n):
            eventContinuation.yield(.buffer(n))
        case .pingAck(let snr, let quality):
            eventContinuation.yield(.linkQuality(snr: snr, quality: quality))
        case .rejectedBW(let peer), .rejectedBusy(let peer):
            currentPeer = nil
            updateState(.error("Rejected by \(peer.value)"))
        case .pending, .cancelPending, .target, .ping, .pingReply,
             .state, .newState, .status, .ack, .unparsed:
            break
        }
    }

    private func handle(frame: DataFrame) {
        switch frame.kind {
        case .arq, .fec:
            guard let peer = currentPeer,
                  let text = String(data: frame.payload, encoding: .utf8) else { return }
            let msg = Message(direction: .received, peer: peer, body: text)
            eventContinuation.yield(.messageReceived(msg))
        case .idf:
            // ID frames carry "CALLSIGN [GRID]" of a station heard on the
            // channel. Surface them so the UI's Heard list can populate.
            guard let text = String(data: frame.payload, encoding: .utf8) else { return }
            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            if let callText = parts.first, let call = Callsign(callText) {
                let grid = parts.count > 1 ? Grid(parts[1]) : nil
                eventContinuation.yield(.heard(call, grid: grid))
            }
        case .err:
            if let text = String(data: frame.payload, encoding: .utf8) {
                eventContinuation.yield(.fault(text))
            }
        case .unknown:
            break
        }
    }
}
