import SwiftUI
import SidetoneCore

/// First-run setup. Collects identity and connection info for a local TNC.
/// Remote-server setup (iOS/iPad Bonjour discovery) lives in a separate
/// view built in M6 — this is the Mac/local path only.
public struct LocalSetupView: View {
    @State private var callsignInput: String
    @State private var gridInput: String
    @State private var host: String
    @State private var port: String

    public var onSubmit: (Callsign, SidetoneCore.Grid?, String, UInt16) -> Void

    public init(
        onSubmit: @escaping (Callsign, SidetoneCore.Grid?, String, UInt16) -> Void,
        defaults: SettingsDefaults = SettingsDefaults()
    ) {
        self.onSubmit = onSubmit
        // Pre-fill from the last successful setup so the operator
        // doesn't have to re-enter their own callsign.
        _callsignInput = State(initialValue: defaults.lastCallsign ?? "")
        _gridInput = State(initialValue: defaults.lastGrid ?? "")
        _host = State(initialValue: defaults.lastArdopcfHost ?? "127.0.0.1")
        _port = State(initialValue: defaults.lastArdopcfPort.map(String.init) ?? "8515")
    }

    @ViewBuilder private var callsignField: some View {
        #if os(iOS)
        TextField("Callsign", text: $callsignInput)
            .textInputAutocapitalization(.characters)
        #else
        TextField("Callsign", text: $callsignInput)
        #endif
    }

    public var body: some View {
        Form {
            Section("Station") {
                callsignField
                    .autocorrectionDisabled()
                    .onChange(of: callsignInput) { _, new in
                        callsignInput = new.uppercased()
                    }
                TextField("Grid (optional)", text: $gridInput)
                    .autocorrectionDisabled()
            }

            Section("ardopcf") {
                TextField("Host", text: $host)
                    .autocorrectionDisabled()
                TextField("Command port", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            Button("Connect") {
                guard let call = Callsign(callsignInput),
                      let port = UInt16(port) else { return }
                onSubmit(call, SidetoneCore.Grid(gridInput), host, port)
            }
            .disabled(Callsign(callsignInput) == nil || UInt16(port) == nil)
        }
        .navigationTitle("Set up Sidetone")
    }
}
