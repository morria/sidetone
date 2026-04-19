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
    }
}

/// Owns the live driver and exposes intents the menu bar and setup view
/// call into. Sits alongside `AppState` — AppState is about state; this is
/// about lifecycle. They split cleanly: AppState never knows how the
/// driver was constructed.
@Observable
@MainActor
final class AppCoordinator {
    let state = AppState()
    private(set) var driver: LocalDriver?
    var setupComplete: Bool = false
    var setupError: String?

    func runSetup(callsign: Callsign, grid: SidetoneCore.Grid?, host: String, commandPort: UInt16) async {
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
        setupComplete = true
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
        if coordinator.setupComplete {
            RootView()
        } else {
            SetupScene()
        }
    }
}

struct SetupScene: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack {
            LocalSetupView { call, grid, host, port in
                Task { await coordinator.runSetup(callsign: call, grid: grid, host: host, commandPort: port) }
            }
            if let err = coordinator.setupError {
                Text(err)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
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
