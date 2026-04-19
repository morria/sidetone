import Foundation

/// Thin wrapper over `UserDefaults` for the handful of settings that
/// need to persist between launches — callsign, grid, ardopcf host,
/// port — so the setup flow remembers the operator's configuration.
///
/// Not SwiftData because these are simple scalars, and not Keychain
/// because they're not sensitive. Tokens go in `KeychainTokenStore`.
public struct SettingsDefaults {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastCallsign: String? {
        get { defaults.string(forKey: Keys.callsign) }
        nonmutating set { defaults.set(newValue, forKey: Keys.callsign) }
    }

    public var lastGrid: String? {
        get { defaults.string(forKey: Keys.grid) }
        nonmutating set { defaults.set(newValue, forKey: Keys.grid) }
    }

    public var lastArdopcfHost: String? {
        get { defaults.string(forKey: Keys.host) }
        nonmutating set { defaults.set(newValue, forKey: Keys.host) }
    }

    public var lastArdopcfPort: UInt16? {
        get {
            let n = defaults.integer(forKey: Keys.port)
            return n > 0 ? UInt16(n) : nil
        }
        nonmutating set {
            defaults.set(Int(newValue ?? 0), forKey: Keys.port)
        }
    }

    public var lastSelectedPeer: String? {
        get { defaults.string(forKey: Keys.peer) }
        nonmutating set { defaults.set(newValue, forKey: Keys.peer) }
    }

    public var lastModeIsRemote: Bool {
        get { defaults.bool(forKey: Keys.modeIsRemote) }
        nonmutating set { defaults.set(newValue, forKey: Keys.modeIsRemote) }
    }

    public var lastServerName: String? {
        get { defaults.string(forKey: Keys.serverName) }
        nonmutating set { defaults.set(newValue, forKey: Keys.serverName) }
    }

    public var lastServerURL: URL? {
        get { (defaults.string(forKey: Keys.serverURL)).flatMap(URL.init(string:)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Keys.serverURL) }
    }

    public func clearAll() {
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let callsign = "net.sidetone.lastCallsign"
        static let grid = "net.sidetone.lastGrid"
        static let host = "net.sidetone.lastArdopcfHost"
        static let port = "net.sidetone.lastArdopcfPort"
        static let peer = "net.sidetone.lastSelectedPeer"
        static let modeIsRemote = "net.sidetone.modeIsRemote"
        static let serverName = "net.sidetone.lastServerName"
        static let serverURL = "net.sidetone.lastServerURL"

        static let all = [callsign, grid, host, port, peer, modeIsRemote, serverName, serverURL]
    }
}
