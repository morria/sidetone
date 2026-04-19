#if os(macOS)
import SwiftUI
import SidetoneCore
import SidetoneUI

/// Compact live-status widget that lives in the system menu bar. Gives
/// the operator one-glance awareness of the session — useful when the
/// main window is buried under Terminal and an ardopcf log.
///
/// Icon encodes state: ● gray = disconnected, 🟢 = listening, 🟡 =
/// connected, 🔴 = transmitting. Actually a monochrome SF Symbol set
/// with a color overlay so it respects light/dark menu bar themes.
struct SidetoneMenuBarExtra: Scene {
    @Bindable var coordinator: AppCoordinator

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(coordinator: coordinator)
        } label: {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(tintColor, .primary)
                .accessibilityLabel(accessibilityDescription)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        if coordinator.state.ptt {
            return "antenna.radiowaves.left.and.right.circle.fill"
        }
        switch coordinator.state.sessionState {
        case .connected:   return "antenna.radiowaves.left.and.right.circle.fill"
        case .connecting:  return "antenna.radiowaves.left.and.right.circle"
        case .listening:   return "ear.fill"
        case .disconnecting, .disconnected, .error: return "antenna.radiowaves.left.and.right"
        }
    }

    private var tintColor: Color {
        if coordinator.state.ptt { return .red }
        switch coordinator.state.sessionState {
        case .connected:   return .yellow
        case .connecting:  return .orange
        case .listening:   return .green
        case .error:       return .red
        case .disconnecting, .disconnected: return .secondary
        }
    }

    private var accessibilityDescription: String {
        if coordinator.state.ptt { return "Sidetone — transmitting" }
        switch coordinator.state.sessionState {
        case .disconnected:                 return "Sidetone — disconnected"
        case .listening:                    return "Sidetone — listening"
        case .connecting(let peer, _):      return "Sidetone — connecting to \(peer.value)"
        case .connected(let peer, _, _):    return "Sidetone — connected to \(peer.value)"
        case .disconnecting:                return "Sidetone — disconnecting"
        case .error(let reason):            return "Sidetone — error: \(reason)"
        }
    }
}

struct MenuBarPopover: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sidetone")
                .font(.headline)

            Divider()

            stateLine
            indicatorsLine

            if let lq = coordinator.state.lastLinkQuality {
                HStack {
                    Text("Quality").font(.caption)
                    Spacer()
                    Text("\(lq.quality)").font(.caption.monospaced())
                }
            }

            Divider()

            Button("Connect to Station…") {
                coordinator.showingConnectSheet = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!coordinator.setupComplete)

            Button("Show Sidetone") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }

            Divider()

            Button("Quit Sidetone") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .frame(width: 260)
    }

    private var stateLine: some View {
        HStack {
            Text("State").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(describe(coordinator.state.sessionState))
                .font(.caption.monospaced())
        }
    }

    private var indicatorsLine: some View {
        HStack(spacing: 12) {
            indicator(on: coordinator.state.ptt, onColor: .red, label: "TX")
            indicator(on: coordinator.state.busy, onColor: .orange, label: "BUSY")
            Spacer()
            Text("buf \(coordinator.state.bufferBytes)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func indicator(on: Bool, onColor: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? onColor : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(label).font(.caption2.monospaced())
                .foregroundStyle(on ? .primary : .secondary)
        }
    }

    private func describe(_ s: SessionState) -> String {
        switch s {
        case .disconnected: return "Disconnected"
        case .listening: return "Listening"
        case .connecting(let peer, _): return "Connecting → \(peer.value)"
        case .connected(let peer, let bw, _): return "\(peer.value) @ \(bw) Hz"
        case .disconnecting: return "Disconnecting"
        case .error(let reason): return "Error: \(reason)"
        }
    }
}
#endif
