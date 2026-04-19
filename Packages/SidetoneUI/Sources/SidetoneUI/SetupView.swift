import SwiftUI
import SidetoneCore

/// First-run setup. Collects identity and connection info for a local TNC.
/// Remote-server setup (iOS/iPad Bonjour discovery) lives in a separate
/// view built in M6 — this is the Mac/local path only.
public struct LocalSetupView: View {
    @State private var callsignInput = ""
    @State private var gridInput = ""
    @State private var host = "127.0.0.1"
    @State private var port = "8515"

    public var onSubmit: (Callsign, SidetoneCore.Grid?, String, UInt16) -> Void

    public init(onSubmit: @escaping (Callsign, SidetoneCore.Grid?, String, UInt16) -> Void) {
        self.onSubmit = onSubmit
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
