import Foundation

/// `SessionDriver` implementation that talks to a Sidetone server over
/// HTTPS + WebSocket. Mirrors the observable behavior of `LocalDriver`
/// so the UI and `AppState` can't tell which driver is attached.
///
/// Uses Foundation-only networking (URLSession + URLSessionWebSocketTask)
/// so the client compiles on iOS/iPadOS/macOS without pulling NIO.
public actor RemoteDriver: SessionDriver {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var token: String?

        public init(baseURL: URL, token: String? = nil) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    public enum RemoteError: Error, Sendable, Equatable {
        case badURL
        case statusCode(Int, body: String)
        case decode(String)
        case websocketClosed
        case notConnected
    }

    public private(set) var sessionState: SessionState = .disconnected
    public nonisolated let events: AsyncStream<SessionEvent>

    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: Configuration
    private let session: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    public func connect() async throws {
        // Establish the WebSocket. The server replays current state as
        // its first event so we don't need a separate GET.
        let wsURL: URL = {
            var components = URLComponents(url: configuration.baseURL.appendingPathComponent("api/v1/events"), resolvingAgainstBaseURL: false)!
            switch components.scheme {
            case "https": components.scheme = "wss"
            case "http": components.scheme = "ws"
            default: break
            }
            return components.url!
        }()
        var request = URLRequest(url: wsURL)
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        wsTask = task
        task.resume()
        startReader()
    }

    public func initiateCall(to peer: Callsign, bandwidth: ARQBandwidth, repeats: Int) async throws {
        let body = APIv1.ConnectRequest(
            callsign: peer.value,
            bandwidth: bandwidth.wireValue,
            repeats: repeats
        )
        _ = try await post("/api/v1/connect", body: body)
        // Don't set local state here; we'll pick it up from the server's
        // next stateChanged broadcast. That keeps the display in lock
        // step with what the server actually observed.
    }

    public func sendText(_ body: String) async throws {
        guard case .connected(let peer, _, _) = sessionState else {
            throw RemoteError.notConnected
        }
        let req = APIv1.MessageRequest(peer: peer.value, body: body)
        _ = try await post("/api/v1/messages", body: req)
    }

    public func sendFile(data: Data, filename: String, mimeType: String) async throws {
        // Raw-binary POST. Metadata is carried via X-Sidetone-* headers
        // so the server doesn't have to parse multipart.
        let url = configuration.baseURL.appendingPathComponent("api/v1/files")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Sidetone-Filename")
        request.setValue(mimeType, forHTTPHeaderField: "X-Sidetone-MimeType")
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.statusCode(0, body: "")
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteError.statusCode(http.statusCode, body: String(data: body, encoding: .utf8) ?? "")
        }
    }

    public func ping(_ peer: Callsign, repeats: Int) async throws {
        // Minor protocol gap: SPEC's /api/v1 list doesn't include a ping
        // endpoint. We reuse /connect with an explicit bandwidth=ping
        // marker if we add it, but for now just no-op on remote clients.
        // Local drivers call this directly on the TNC.
    }

    public func setListen(_ enabled: Bool) async throws {
        let req = APIv1.ListenRequest(enabled: enabled)
        _ = try await post("/api/v1/listen", body: req)
    }

    public func hangup(graceful: Bool) async throws {
        if graceful {
            _ = try await post("/api/v1/disconnect", body: EmptyBody())
        } else {
            _ = try await post("/api/v1/abort", body: EmptyBody())
        }
    }

    public func shutdown() async {
        readerTask?.cancel()
        readerTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        eventContinuation.finish()
    }

    // MARK: - Internals

    private struct EmptyBody: Codable, Sendable {}

    private func startReader() {
        let cont = eventContinuation
        readerTask = Task { [weak self, wsTask] in
            guard let task = wsTask else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self?.handleWebSocketMessage(message, continuation: cont)
                } catch {
                    cont.yield(.fault("websocket: \(error.localizedDescription)"))
                    return
                }
            }
        }
    }

    private func handleWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        continuation: AsyncStream<SessionEvent>.Continuation
    ) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }

        guard let envelope = try? JSONDecoder().decode(APIv1.EventEnvelope.self, from: data) else {
            return
        }

        switch envelope.kind {
        case APIv1.EventKind.stateChanged:
            if let dto = try? envelope.data.decode(as: APIv1.SessionStateDTO.self) {
                sessionState = dto.asValue
                continuation.yield(.stateChanged(dto.asValue))
            }
        case APIv1.EventKind.messageReceived:
            if let dto = try? envelope.data.decode(as: APIv1.MessageDTO.self),
               let msg = dto.asValue {
                continuation.yield(.messageReceived(msg))
            }
        case APIv1.EventKind.messageSent:
            if let dto = try? envelope.data.decode(as: APIv1.MessageDTO.self),
               let msg = dto.asValue {
                continuation.yield(.messageSent(msg))
            }
        case APIv1.EventKind.linkQuality:
            if let lq = try? envelope.data.decode(as: APIv1.LinkQualityEvent.self) {
                continuation.yield(.linkQuality(snr: lq.snr, quality: lq.quality))
            }
        case APIv1.EventKind.ptt:
            if let b = try? envelope.data.decode(as: APIv1.BoolEvent.self) {
                continuation.yield(.ptt(b.value))
            }
        case APIv1.EventKind.busy:
            if let b = try? envelope.data.decode(as: APIv1.BoolEvent.self) {
                continuation.yield(.busy(b.value))
            }
        case APIv1.EventKind.buffer:
            if let i = try? envelope.data.decode(as: APIv1.IntEvent.self) {
                continuation.yield(.buffer(i.value))
            }
        case APIv1.EventKind.fault:
            if let f = try? envelope.data.decode(as: APIv1.FaultEvent.self) {
                continuation.yield(.fault(f.message))
            }
        case APIv1.EventKind.heard:
            if let dto = try? envelope.data.decode(as: APIv1.StationDTO.self),
               let call = Callsign(dto.callsign) {
                continuation.yield(.heard(call, grid: dto.grid.flatMap(Grid.init)))
            }
        default:
            // Unknown kind — silent skip by design. Server can add new
            // kinds without breaking old clients.
            break
        }
    }

    private func post<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let url = configuration.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.statusCode(0, body: "")
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteError.statusCode(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
