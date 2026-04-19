import SwiftUI
import SidetoneCore

/// Modal for initiating an ARQ call. Lets the operator pick a saved
/// station or type a fresh callsign, choose the ARQ bandwidth and
/// connect-frame repeats, then hits Connect.
///
/// Intentionally small — the only interesting bit is that the call
/// happens via `AppState.connect(to:bandwidth:repeats:)` so the same
/// dialog works for a local or remote driver.
public struct ConnectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var targetInput: String = ""
    @State private var bandwidth: BandwidthChoice = .hz500
    @State private var repeats: Int = 5
    @State private var error: String?
    @State private var submitting = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    callsignField

                    if !state.stations.isEmpty {
                        Picker("From saved", selection: $targetInput) {
                            Text("Choose…").tag("")
                            ForEach(state.stations) { station in
                                Text(station.callsign.value).tag(station.callsign.value)
                            }
                        }
                    }
                }

                Section("ARQ parameters") {
                    Picker("Bandwidth", selection: $bandwidth) {
                        ForEach(BandwidthChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    Stepper("Connect-frame repeats: \(repeats)", value: $repeats, in: 1...10)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect to station")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { Task { await connect() } }
                        .disabled(Callsign(targetInput) == nil || submitting)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func connect() async {
        guard let call = Callsign(targetInput) else { return }
        error = nil
        submitting = true
        defer { submitting = false }
        do {
            try await state.connect(to: call, bandwidth: bandwidth.toCore, repeats: repeats)
            dismiss()
        } catch {
            self.error = "Couldn't start the call: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var callsignField: some View {
        #if os(iOS)
        TextField("Callsign", text: $targetInput)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .onChange(of: targetInput) { _, new in targetInput = new.uppercased() }
        #else
        TextField("Callsign", text: $targetInput)
            .autocorrectionDisabled()
            .onChange(of: targetInput) { _, new in targetInput = new.uppercased() }
        #endif
    }

    enum BandwidthChoice: String, CaseIterable, Identifiable {
        case hz200 = "200 Hz"
        case hz500 = "500 Hz"
        case hz1000 = "1000 Hz"
        case hz2000 = "2000 Hz"
        var id: String { rawValue }

        var toCore: ARQBandwidth {
            switch self {
            case .hz200:  return .hz200(forced: false)
            case .hz500:  return .hz500(forced: false)
            case .hz1000: return .hz1000(forced: false)
            case .hz2000: return .hz2000(forced: false)
            }
        }
    }
}
