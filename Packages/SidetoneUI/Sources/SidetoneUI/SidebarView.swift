import SwiftUI
import SidetoneCore

public struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Callsign?
    @State private var showingAdd = false

    public init(selection: Binding<Callsign?>) {
        self._selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            if !state.stations.isEmpty {
                Section("Stations") {
                    ForEach(state.stations) { station in
                        StationRow(station: station, indicator: indicator(for: station.callsign))
                            .tag(station.callsign)
                    }
                }
            } else {
                Section("Stations") {
                    Text("No saved stations yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !state.heard.isEmpty {
                Section("Heard") {
                    ForEach(state.heard) { station in
                        StationRow(station: station, indicator: .heardRecently)
                            .tag(station.callsign)
                    }
                }
            }
        }
        .toolbar {
            Button {
                showingAdd = true
            } label: {
                Label("New station", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddStationSheet()
        }
        .navigationTitle("Sidetone")
    }

    private func indicator(for callsign: Callsign) -> StationRow.Indicator {
        if case let .connected(peer, _, _) = state.sessionState, peer == callsign {
            return .inSession
        }
        if state.heard.contains(where: { $0.callsign == callsign }) {
            return .heardRecently
        }
        return .idle
    }
}

struct StationRow: View {
    enum Indicator {
        case inSession, heardRecently, idle

        var color: Color {
            switch self {
            case .inSession:     .yellow
            case .heardRecently: .green
            case .idle:          .secondary
            }
        }
    }

    let station: Station
    let indicator: Indicator

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicator.color)
                .frame(width: 8, height: 8)
            Text(station.callsign.value)
                .font(.body.monospaced())
            Spacer()
            if let grid = station.grid {
                Text(grid.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(station.callsign.value), \(accessibilityDescription)")
    }

    private var accessibilityDescription: String {
        switch indicator {
        case .inSession:     "in session"
        case .heardRecently: "heard recently"
        case .idle:          "not heard this session"
        }
    }
}

struct AddStationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var callsignInput = ""
    @State private var gridInput = ""
    @State private var notes = ""

    @ViewBuilder private var callsignField: some View {
        #if os(iOS)
        TextField("Callsign", text: $callsignInput)
            .textInputAutocapitalization(.characters)
        #else
        TextField("Callsign", text: $callsignInput)
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    callsignField
                        .autocorrectionDisabled()
                        .onChange(of: callsignInput) { _, newValue in
                            callsignInput = newValue.uppercased()
                        }
                    TextField("Grid square (optional)", text: $gridInput)
                        .autocorrectionDisabled()
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("New station")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let call = Callsign(callsignInput) else { return }
                        let grid = Grid(gridInput)
                        state.saveStation(Station(callsign: call, grid: grid, notes: notes))
                        dismiss()
                    }
                    .disabled(Callsign(callsignInput) == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
