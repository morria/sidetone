import Foundation
import SidetoneCore

/// Builds the production route table for a live `ServerHost`. Kept as
/// a top-level function rather than baked into the Router so tests can
/// construct alternative tables without a running session.
///
/// When `pairing` is non-nil every non-`/pair` endpoint requires a
/// valid Bearer token; nil means "no auth" (dev mode). The pair
/// endpoint is always public — that's how a client becomes trusted.
public enum Endpoints {
    public static func routes(
        host: ServerHost,
        store: PersistenceStore?,
        pairing: PairingRegistry? = nil,
        certificateFingerprint: String = ""
    ) -> Router {
        let authCheck: @Sendable (Request) async -> Response? = { request in
            guard let pairing else { return nil }
            let header = request.headers["authorization"] ?? ""
            guard header.hasPrefix("Bearer "),
                  await pairing.verify(token: String(header.dropFirst("Bearer ".count))) != nil else {
                return (try? Response.error("unauthorized", message: "missing or invalid token", status: 401)) ?? Response(status: 401)
            }
            return nil
        }

        func protected(_ method: String, _ path: String, _ handler: @Sendable @escaping (Request) async throws -> Response) -> Route {
            Route(method: method, path: path) { request in
                if let denied = await authCheck(request) { return denied }
                return try await handler(request)
            }
        }

        return Router([
            // Public: the only way a new device becomes trusted.
            Route(method: "POST", path: "/api/v1/pair") { request in
                guard let pairing else {
                    return try Response.error("pairing_disabled", message: "server not configured for pairing", status: 409)
                }
                let body = try request.decode(APIv1.PairRequest.self)
                do {
                    let device = try await pairing.exchange(code: body.code, deviceName: body.deviceName)
                    return try Response.json(APIv1.PairResponse(
                        token: device.token,
                        certificateFingerprint: certificateFingerprint,
                        serverName: Host.current().localizedName ?? "sidetone-server"
                    ))
                } catch PairingRegistry.PairingError.wrongCode {
                    return try Response.error("wrong_code", message: "code does not match", status: 401)
                } catch PairingRegistry.PairingError.codeExpired {
                    return try Response.error("code_expired", message: "pairing code expired", status: 401)
                } catch PairingRegistry.PairingError.pairingNotActive {
                    return try Response.error("pairing_inactive", message: "server is not in pairing mode", status: 409)
                }
            },

            protected("GET", "/api/v1/status") { _ in
                let snap = await host.snapshot()
                return try Response.json(snap)
            },

            protected("GET", "/api/v1/stations") { _ in
                guard let store = await host.persistence ?? store else {
                    return Response(
                        status: 200,
                        headers: ["Content-Type": "application/json; charset=utf-8"],
                        body: Data(#"{"stations":[]}"#.utf8)
                    )
                }
                let stations = try await storeMainActorHop { try store.allStations().map(APIv1.StationDTO.init) }
                return try Response.json(APIv1.StationsResponse(stations: stations))
            },

            protected("POST", "/api/v1/stations") { request in
                let dto = try request.decode(APIv1.StationDTO.self)
                guard let station = dto.asValue else {
                    return try Response.error("bad_callsign", message: "callsign failed validation", status: 400)
                }
                if let store = await host.persistence ?? store {
                    try await storeMainActorHop { try store.saveStation(station) }
                }
                return try Response.json(APIv1.StationDTO(station), status: 201)
            },

            protected("POST", "/api/v1/connect") { request in
                let body = try request.decode(APIv1.ConnectRequest.self)
                guard let call = Callsign(body.callsign) else {
                    return try Response.error("bad_callsign", message: "callsign failed validation", status: 400)
                }
                let bw = parseBandwidth(body.bandwidth) ?? .hz500(forced: false)
                try await host.connect(to: call, bandwidth: bw, repeats: body.repeats ?? 5)
                return Response(status: 202)
            },

            protected("POST", "/api/v1/disconnect") { _ in
                try await host.disconnect(graceful: true)
                return Response(status: 202)
            },

            protected("POST", "/api/v1/abort") { _ in
                try await host.disconnect(graceful: false)
                return Response(status: 202)
            },

            protected("POST", "/api/v1/listen") { request in
                let body = try request.decode(APIv1.ListenRequest.self)
                try await host.setListen(body.enabled)
                return Response(status: 202)
            },

            protected("GET", "/api/v1/log") { request in
                let limit = Int(request.query["limit"] ?? "") ?? 200
                guard let store = await host.persistence ?? store else {
                    return try Response.json(APIv1.MessagesResponse(messages: []))
                }
                let messages = try await storeMainActorHop {
                    try store.recentActivity(limit: limit).map(APIv1.MessageDTO.init)
                }
                return try Response.json(APIv1.MessagesResponse(messages: messages))
            },

            protected("POST", "/api/v1/messages") { request in
                let body = try request.decode(APIv1.MessageRequest.self)
                try await host.sendText(body.body)
                return Response(status: 202)
            },

            protected("POST", "/api/v1/files") { request in
                // Raw-binary upload: the filename and MIME come via
                // X-Sidetone-* headers, the body is the file bytes.
                // Keeps the endpoint simple — no multipart parsing.
                guard let filename = request.headers["x-sidetone-filename"],
                      !filename.isEmpty else {
                    return try Response.error("missing_filename", message: "X-Sidetone-Filename required")
                }
                let mimeType = request.headers["x-sidetone-mimetype"]
                    ?? request.headers["content-type"]
                    ?? "application/octet-stream"
                try await host.sendFile(
                    data: request.body,
                    filename: filename,
                    mimeType: mimeType
                )
                return Response(status: 202)
            },
        ])
    }

    private static func parseBandwidth(_ raw: String?) -> ARQBandwidth? {
        guard let raw = raw?.uppercased() else { return nil }
        let forced = raw.hasSuffix("FORCED")
        let digits = raw
            .replacingOccurrences(of: "FORCED", with: "")
            .replacingOccurrences(of: "MAX", with: "")
        switch digits {
        case "200": return .hz200(forced: forced)
        case "500": return .hz500(forced: forced)
        case "1000": return .hz1000(forced: forced)
        case "2000": return .hz2000(forced: forced)
        default: return nil
        }
    }
}

/// The PersistenceStore is `@MainActor`-isolated, so reads from a
/// `Sendable` closure need to hop there. This helper keeps every
/// endpoint from repeating the same `await MainActor.run` dance.
@MainActor
private func storeMainActorHop<T: Sendable>(_ block: @MainActor () throws -> T) async throws -> T {
    try block()
}
