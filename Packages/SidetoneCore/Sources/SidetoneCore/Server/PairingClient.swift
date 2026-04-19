import Foundation

/// Client-side pairing helper. Exchanges a 6-digit code shown on the
/// server for a persistent token the caller should stash in Keychain.
///
/// Intentionally tiny — deliberately not part of `RemoteDriver`
/// because pairing happens before there's a session to talk to, and
/// we don't want to couple pairing bugs to the driver lifecycle.
public struct PairingClient: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case badServer
        case wrongCode
        case codeExpired
        case pairingInactive
        case transport(String)
    }

    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func pair(code: String, deviceName: String) async throws -> APIv1.PairResponse {
        let url = baseURL.appendingPathComponent("api/v1/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(APIv1.PairRequest(code: code, deviceName: deviceName))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.badServer
        }
        if http.statusCode == 200 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(APIv1.PairResponse.self, from: data)
            } catch {
                throw Failure.badServer
            }
        }

        if let err = try? JSONDecoder().decode(APIv1.ErrorResponse.self, from: data) {
            switch err.code {
            case "wrong_code":       throw Failure.wrongCode
            case "code_expired":     throw Failure.codeExpired
            case "pairing_inactive",
                 "pairing_disabled": throw Failure.pairingInactive
            default: throw Failure.badServer
            }
        }
        throw Failure.badServer
    }
}
