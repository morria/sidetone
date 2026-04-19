import SwiftUI
import SidetoneCore
import SidetoneUI

/// Mac entry point. Owns the `AppState` and the live `LocalDriver`, wires
/// them together once the user completes the setup flow.
///
/// This is an SPM `.executableTarget` for now so we can `swift run SidetoneMac`
/// during M2 development. A proper `Sidetone.xcodeproj` that produces a
/// signed `.app` bundle is a separate deliverable in M8 polish.
@main
struct SidetoneMacApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootScene()
                .environment(coordinator.state)
                .environment(coordinator)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            SidetoneMenus(coordinator: coordinator)
        }

        Settings {
            SettingsView()
                .environment(coordinator)
        }

        SidetoneMenuBarExtra(coordinator: coordinator)
    }
}

/// Owns the live driver and exposes intents the menu bar and setup view
/// call into. Sits alongside `AppState` — AppState is about state; this is
/// about lifecycle. They split cleanly: AppState never knows how the
/// driver was constructed.
@Observable
@MainActor
final class AppCoordinator {
    enum Mode: Equatable { case local, remote }

    let state = AppState()
    private(set) var driver: (any SessionDriver)?
    var setupComplete: Bool = false
    var setupError: String?
    var mode: Mode = .local
    var showingConnectSheet: Bool = false
    var showingHelp: Bool = false
    var showingLog: Bool = false
    let persistenceStore: PersistenceStore? = try? PersistenceStore(.defaultApplicationSupport)
    let defaults = SettingsDefaults()

    func runLocalSetup(callsign: Callsign, grid: SidetoneCore.Grid?, host: String, commandPort: UInt16) async {
        setupError = nil
        let tnc = TNCClient(configuration: .init(host: host, commandPort: commandPort))
        let driver = LocalDriver(tnc: tnc, myCall: callsign, grid: grid)
        do {
            try await driver.connect()
        } catch {
            setupError = "Could not reach ardopcf at \(host):\(commandPort) — \(error.localizedDescription)"
            return
        }
        self.driver = driver
        state.attach(driver, identity: .init(callsign: callsign, grid: grid))
        mode = .local
        setupComplete = true

        // Persist for next launch so the operator doesn't re-type this
        // every time they open the app.
        defaults.lastCallsign = callsign.value
        defaults.lastGrid = grid?.value
        defaults.lastArdopcfHost = host
        defaults.lastArdopcfPort = commandPort
        defaults.lastModeIsRemote = false
    }

    func runRemoteSetup(credential: ServerCredential, baseURL: URL) async {
        setupError = nil
        // If the server advertised a cert fingerprint at pairing time,
        // pin it. Clients never silently accept self-signed certs.
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
            setupError = "Could not reach Sidetone server at \(baseURL.absoluteString) — \(error.localizedDescription)"
            return
        }
        self.driver = driver
        // Identity comes back from the server via /status; we seed a
        // placeholder so AppState has *something* until that lands.
        if let call = Callsign("REMOTE1") {
            state.attach(driver, identity: .init(callsign: call))
        }
        mode = .remote
        setupComplete = true

        defaults.lastModeIsRemote = true
        defaults.lastServerName = credential.serverName
        defaults.lastServerURL = baseURL
    }

    func disconnect() async {
        await state.detach()
        driver = nil
        setupComplete = false
    }
}

struct RootScene: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            if coordinator.setupComplete {
                RootView()
            } else {
                SetupScene()
            }
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showingConnectSheet },
            set: { coordinator.showingConnectSheet = $0 }
        )) {
            ConnectSheet()
                .environment(coordinator.state)
                .frame(minWidth: 380, minHeight: 340)
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showingHelp },
            set: { coordinator.showingHelp = $0 }
        )) {
            HelpView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showingLog },
            set: { coordinator.showingLog = $0 }
        )) {
            NavigationStack {
                LogView(
                    entries: (try? coordinator.persistenceStore?.recentActivity()) ?? [],
                    myCall: coordinator.state.myCall,
                    myGrid: coordinator.state.myGrid
                )
            }
            .frame(minWidth: 520, minHeight: 400)
        }
    }
}

struct SetupScene: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var mode: ModeChoice = .local
    @State private var remoteCoordinator: RemoteSetupView.Coordinator?

    enum ModeChoice: String, CaseIterable, Identifiable {
        case local = "Local ardopcf"
        case remote = "Remote Sidetone server"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Setup type", selection: $mode) {
                ForEach(ModeChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .local:
                LocalSetupView { call, grid, host, port in
                    Task { await coordinator.runLocalSetup(callsign: call, grid: grid, host: host, commandPort: port) }
                }
            case .remote:
                RemoteSetupView(coordinator: remoteCoordinator ?? makeRemoteCoordinator())
            }

            if let err = coordinator.setupError {
                Text(err)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            if remoteCoordinator == nil { remoteCoordinator = makeRemoteCoordinator() }
        }
    }

    private func makeRemoteCoordinator() -> RemoteSetupView.Coordinator {
        let coord = RemoteSetupView.Coordinator(
            tokenStore: KeychainTokenStore(),
            onPairComplete: { [coordinator] credential, url in
                Task { @MainActor in
                    await coordinator.runRemoteSetup(credential: credential, baseURL: url)
                }
            }
        )
        return coord
    }
}

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Form {
            if let identity = coordinator.driver.map({ _ in (coordinator.state.myCall, coordinator.state.myGrid) }) {
                Section("Station") {
                    LabeledContent("Call") {
                        Text(identity.0?.value ?? "—").font(.body.monospaced())
                    }
                    LabeledContent("Grid") {
                        Text(identity.1?.value ?? "—").font(.body.monospaced())
                    }
                }
            } else {
                Text("Finish setup to see station preferences.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 420, height: 240)
    }
}
