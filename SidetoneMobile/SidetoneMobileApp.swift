import SwiftUI
import SidetoneCore
import SidetoneUI

/// iPhone / iPad entry point. Always a client — iOS never runs ardopcf
/// itself (Apple's audio sandbox makes it impractical). The app talks
/// to a Sidetone server running on a Mac or a Pi on the same network.
///
/// Flow: auto-reconnect if we have a previously-paired server in
/// Keychain, otherwise show the Bonjour-driven pairing setup. Once
/// connected, the shared `RootView` from `SidetoneUI` takes over —
/// same code the Mac app uses, adaptive layout handles the phone /
/// iPad split automatically.
@main
struct SidetoneMobileApp: App {
    @State private var coordinator = MobileCoordinator()
    @State private var setupCoordinator: RemoteSetupView.Coordinator?

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(coordinator.state)
                .environment(coordinator)
                .task { await coordinator.attemptAutoReconnect() }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if coordinator.setupComplete {
            RootView()
        } else if coordinator.checkingAutoReconnect {
            ProgressView("Reconnecting…")
                .progressViewStyle(.circular)
        } else {
            NavigationStack {
                if let setup = setupCoordinator {
                    RemoteSetupView(coordinator: setup)
                } else {
                    Color.clear.onAppear {
                        setupCoordinator = coordinator.makeSetupCoordinator()
                    }
                }
            }
        }
    }
}

/// Owns the live `RemoteDriver`. Counterpart to the Mac `AppCoordinator`
/// but stripped down — iOS clients have no local-driver path to choose.
@Observable
@MainActor
final class MobileCoordinator {
    let state = AppState()
    private(set) var driver: RemoteDriver?
    var setupComplete = false
    var setupError: String?
    var checkingAutoReconnect = true

    let tokenStore: TokenStore = KeychainTokenStore()
    let defaults = SettingsDefaults()

    /// Build a setup-flow coordinator tied to this instance. The view
    /// holds it in its own @State so the pair-complete closure can
    /// capture `self` weakly without the init-order dance `@Observable`
    /// makes impossible inside the owning class.
    func makeSetupCoordinator() -> RemoteSetupView.Coordinator {
        RemoteSetupView.Coordinator(
            tokenStore: tokenStore,
            onPairComplete: { [weak self] credential, url in
                Task { @MainActor in
                    await self?.finishSetup(credential: credential, baseURL: url)
                }
            }
        )
    }

    /// Attempt to reconnect to the last paired server without user
    /// interaction. Called from `.task { }` at launch so it runs on a
    /// short yield rather than blocking the first paint.
    func attemptAutoReconnect() async {
        defer { checkingAutoReconnect = false }
        guard let serverName = defaults.lastServerName,
              let url = defaults.lastServerURL,
              let credential = try? tokenStore.credential(for: serverName) else {
            return
        }
        await finishSetup(credential: credential, baseURL: url)
    }

    func signOut() async {
        await state.detach()
        driver = nil
        setupComplete = false
        if let server = defaults.lastServerName {
            try? tokenStore.delete(serverName: server)
        }
        defaults.lastServerName = nil
        defaults.lastServerURL = nil
    }

    private func finishSetup(credential: ServerCredential, baseURL: URL) async {
        setupError = nil
        let session: URLSession = {
            guard !credential.certificateFingerprint.isEmpty else {
                return .shared
            }
            let delegate = PinnedTLSDelegate(expectedFingerprintSHA256: credential.certificateFingerprint)
            return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }()
        let driver = RemoteDriver(
            configuration: .init(baseURL: baseURL, token: credential.token),
            session: session
        )
        do {
            try await driver.connect()
        } catch {
            setupError = "Couldn't reach \(credential.serverName): \(error.localizedDescription)"
            return
        }
        self.driver = driver
        // Identity (callsign / grid) comes from the server's /status
        // snapshot over the WebSocket. Until that arrives, AppState
        // carries a placeholder — the UI keys off sessionState, not
        // identity, so this doesn't show up to the user.
        if let call = Callsign("REMOTE1") {
            state.attach(driver, identity: .init(callsign: call))
        }
        defaults.lastServerName = credential.serverName
        defaults.lastServerURL = baseURL
        defaults.lastModeIsRemote = true
        setupComplete = true
    }
}
