import SwiftUI
import SidetoneCore

/// First-run flow for iOS/iPad (and Mac in remote mode): browse Bonjour
/// for Sidetone servers on the LAN, pick one, enter the pairing code
/// the server is showing, and receive a persistent token.
///
/// The view is stateless beyond local form entry — all persistence and
/// networking go through the `Coordinator` the host app supplies. That
/// lets us stub the networking in previews and tests.
public struct RemoteSetupView: View {
    @MainActor
    public final class Coordinator: ObservableObject {
        @Published public var discovered: [BonjourBrowser.DiscoveredServer] = []
        @Published public var selected: BonjourBrowser.DiscoveredServer?
        @Published public var manualHost: String = ""
        @Published public var manualPort: String = "8080"
        @Published public var code: String = ""
        @Published public var deviceName: String = hostDeviceName()
        @Published public var errorText: String?
        @Published public var pairing: Bool = false

        public let onPairComplete: @Sendable (ServerCredential, URL) -> Void
        public let tokenStore: TokenStore

        private var browserTask: Task<Void, Never>?
        private var browser: BonjourBrowser?

        public init(
            tokenStore: TokenStore = InMemoryTokenStore(),
            onPairComplete: @escaping @Sendable (ServerCredential, URL) -> Void
        ) {
            self.tokenStore = tokenStore
            self.onPairComplete = onPairComplete
        }

        public func startBrowsing() {
            let browser = BonjourBrowser()
            self.browser = browser
            browser.start()
            let stream = browser.servers
            browserTask = Task { [weak self] in
                for await list in stream {
                    await MainActor.run {
                        self?.discovered = list
                    }
                }
            }
        }

        public func stopBrowsing() {
            browserTask?.cancel()
            browserTask = nil
            browser?.stop()
            browser = nil
        }

        public func submit() async {
            errorText = nil
            guard let url = resolveURL() else {
                errorText = "Please pick a server or enter a host."
                return
            }
            pairing = true
            defer { pairing = false }

            let client = PairingClient(baseURL: url)
            do {
                let response = try await client.pair(code: code, deviceName: deviceName)
                let credential = ServerCredential(
                    serverName: response.serverName,
                    token: response.token,
                    certificateFingerprint: response.certificateFingerprint
                )
                try tokenStore.save(credential)
                onPairComplete(credential, url)
            } catch PairingClient.Failure.wrongCode {
                errorText = "That code doesn't match. Check the server and try again."
            } catch PairingClient.Failure.codeExpired {
                errorText = "The pairing code expired. Generate a new one on the server."
            } catch PairingClient.Failure.pairingInactive {
                errorText = "The server isn't accepting new devices right now."
            } catch {
                errorText = "Couldn't reach the server: \(error.localizedDescription)"
            }
        }

        private func resolveURL() -> URL? {
            if let selected, let portStr = selected.metadata["port"], let port = Int(portStr) {
                // Bonjour gave us the service. Hostname resolution
                // happens when we open a real connection; for pair-over-
                // HTTP we need a host string. Use the service name with
                // `.local.` suffix, which mDNS should resolve on the LAN.
                return URL(string: "http://\(selected.name).local.:\(port)")
            }
            guard !manualHost.isEmpty, let port = Int(manualPort) else { return nil }
            return URL(string: "http://\(manualHost):\(port)")
        }

        private static func hostDeviceName() -> String {
            #if os(iOS)
            return ProcessInfo.processInfo.hostName
            #else
            return Host.current().localizedName ?? "Sidetone Client"
            #endif
        }
    }

    @StateObject var coordinator: Coordinator

    public init(coordinator: Coordinator) {
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    public var body: some View {
        Form {
            Section("Found on your network") {
                if coordinator.discovered.isEmpty {
                    Text("Scanning…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.discovered) { server in
                        serverRow(server)
                    }
                }
            }

            Section("Or enter manually") {
                TextField("Host", text: $coordinator.manualHost)
                    .autocorrectionDisabled()
                TextField("Port", text: $coordinator.manualPort)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            Section("Pairing") {
                TextField("6-digit code", text: $coordinator.code)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField("Device name", text: $coordinator.deviceName)
            }

            if let err = coordinator.errorText {
                Section {
                    Text(err).foregroundStyle(.red)
                }
            }

            Button {
                Task { await coordinator.submit() }
            } label: {
                HStack {
                    if coordinator.pairing { ProgressView().controlSize(.small) }
                    Text("Pair")
                }
            }
            .disabled(coordinator.code.isEmpty || coordinator.pairing)
        }
        .navigationTitle("Add Sidetone server")
        .onAppear { coordinator.startBrowsing() }
        .onDisappear { coordinator.stopBrowsing() }
    }

    @ViewBuilder
    private func serverRow(_ server: BonjourBrowser.DiscoveredServer) -> some View {
        Button {
            coordinator.selected = server
        } label: {
            HStack {
                Image(systemName: coordinator.selected == server ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(coordinator.selected == server ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading) {
                    Text(server.name).font(.body.monospaced())
                    if let port = server.metadata["port"] {
                        Text("port \(port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
