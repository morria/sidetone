import SwiftUI
import SidetoneCore
import SidetoneUI

/// Menu bar chrome per SPEC.md §Platform-specific chrome → Mac.
///
/// Matches the spec's Connection / Radio / View menu layout as far as the
/// current functionality reaches. Items that need M4+ (rigctld) are
/// present but disabled for now, so the menu reads as complete to the
/// user and we don't shuffle later.
struct SidetoneMenus: Commands {
    @Bindable var coordinator: AppCoordinator

    var body: some Commands {
        CommandMenu("Connection") {
            Button("Connect to Station…") {
                coordinator.showingConnectSheet = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!coordinator.setupComplete)

            Button("Disconnect") {
                Task { try? await coordinator.state.hangup(graceful: true) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canHangup(coordinator.state.sessionState))

            Button("Abort") {
                Task { try? await coordinator.state.hangup(graceful: false) }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!canHangup(coordinator.state.sessionState))

            Divider()

            Toggle("Listen", isOn: listeningBinding)
                .disabled(!coordinator.setupComplete)

            Button("Ping…") {
                coordinator.showingConnectSheet = true  // piggyback on same dialog
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!coordinator.setupComplete)

            Button("Send ID") {
                // Hook into SessionDriver.sendID in a follow-up — driver
                // protocol needs the method added first.
            }
            .disabled(!coordinator.setupComplete)
        }

        CommandMenu("View") {
            Button("Activity Log…") {
                coordinator.showingLog = true
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        CommandMenu("Radio") {
            Button("Tune…") {}
                .disabled(true)
            Button("Set frequency…") {}
                .disabled(true)
            Button("Set mode…") {}
                .disabled(true)
        }

        // Replace the default Help menu with our own so the link goes
        // to the in-app help rather than a missing Apple help book.
        CommandGroup(replacing: .help) {
            Button("Sidetone Help") {
                coordinator.showingHelp = true
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }

    private func canHangup(_ s: SessionState) -> Bool {
        switch s {
        case .connected, .connecting, .listening: true
        default: false
        }
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { if case .listening = coordinator.state.sessionState { true } else { false } },
            set: { newValue in
                Task { try? await coordinator.state.toggleListen(newValue) }
            }
        )
    }
}
