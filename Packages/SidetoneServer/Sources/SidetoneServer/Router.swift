import Foundation
import SidetoneCore

/// Maps HTTP method + path to a handler. A handler takes the raw request
/// body (ASCII or JSON) plus any path parameters and returns a
/// `Response` with status + body.
///
/// This is deliberately not a full URL-template router — we only
/// recognize the exact endpoints in `SPEC §API sketch`. That keeps the
/// surface small and the parsing predictable. Extending to new
/// endpoints means adding explicit rows to the route table.
public struct Route: Sendable {
    public let method: String
    public let path: String
    public let handler: @Sendable (Request) async throws -> Response

    public init(method: String, path: String, handler: @Sendable @escaping (Request) async throws -> Response) {
        self.method = method.uppercased()
        self.path = path
        self.handler = handler
    }
}

public struct Request: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body)
    }
}

public struct Response: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(value)
        return Response(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    public static func error(_ code: String, message: String, status: Int = 400) throws -> Response {
        try .json(APIv1.ErrorResponse(code: code, message: message), status: status)
    }

    public static let notFound = Response(
        status: 404,
        headers: ["Content-Type": "application/json; charset=utf-8"],
        body: Data(#"{"code":"not_found","message":"no route"}"#.utf8)
    )
}

public struct Router: Sendable {
    private let routes: [Route]

    public init(_ routes: [Route]) {
        self.routes = routes
    }

    public func dispatch(_ request: Request) async throws -> Response {
        for route in routes where route.method == request.method && route.path == request.path {
            return try await route.handler(request)
        }
        return .notFound
    }
}
