import Foundation
import SidetoneCore

/// Server-side pairing and token state.
///
/// Flow per SPEC §Transport:
/// 1. Admin enables pairing mode (UI button or first-run sheet) — a
///    6-digit code is generated and displayed on the Mac.
/// 2. Client sends `POST /api/v1/pair` with `{ code, deviceName }`.
/// 3. Server validates the code and issues a persistent opaque token,
///    recording the device name in the registry.
/// 4. Pairing mode auto-closes after a single successful pair, or
///    after a ~5 minute timeout if nobody pairs.
/// 5. All subsequent requests from that device carry
///    `Authorization: Bearer <token>`.
public actor PairingRegistry {
    public struct PairedDevice: Codable, Hashable, Sendable {
        public let token: String
        public let deviceName: String
        public let pairedAt: Date
    }

    public enum PairingError: Error, Sendable, Equatable {
        case pairingNotActive
        case wrongCode
        case codeExpired
    }

    private var activeCode: String?
    private var codeExpiresAt: Date?
    private var devices: [String: PairedDevice] = [:]

    public init() {}

    // MARK: - Admin controls

    /// Generate a new 6-digit code and enter pairing mode. The code
    /// expires in `ttl` seconds (default 300 = 5 minutes).
    public func beginPairing(ttl: TimeInterval = 300) -> String {
        let code = Self.generateCode()
        activeCode = code
        codeExpiresAt = Date().addingTimeInterval(ttl)
        return code
    }

    public func cancelPairing() {
        activeCode = nil
        codeExpiresAt = nil
    }

    public func isPairingActive() -> Bool {
        guard let expires = codeExpiresAt else { return false }
        return Date() < expires
    }

    // MARK: - Client-facing

    /// Exchange a pairing code for a token. Idempotent on correct code
    /// within the validity window; after first success, pairing mode
    /// auto-closes.
    public func exchange(code: String, deviceName: String) throws -> PairedDevice {
        guard let active = activeCode, let expires = codeExpiresAt else {
            throw PairingError.pairingNotActive
        }
        guard Date() < expires else {
            activeCode = nil
            codeExpiresAt = nil
            throw PairingError.codeExpired
        }
        guard active == code else {
            throw PairingError.wrongCode
        }
        let device = PairedDevice(
            token: Self.generateToken(),
            deviceName: deviceName,
            pairedAt: Date()
        )
        devices[device.token] = device
        // Single-use on success: each pairing needs a fresh code.
        activeCode = nil
        codeExpiresAt = nil
        return device
    }

    public func verify(token: String) -> PairedDevice? {
        devices[token]
    }

    public func revoke(token: String) {
        devices.removeValue(forKey: token)
    }

    public func pairedDevices() -> [PairedDevice] {
        Array(devices.values).sorted { $0.pairedAt < $1.pairedAt }
    }

    // MARK: - Helpers

    private static func generateCode() -> String {
        (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    private static func generateToken() -> String {
        // 256 bits of entropy, URL-safe. Good enough for LAN auth.
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
