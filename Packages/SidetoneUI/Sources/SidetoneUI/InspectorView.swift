import SwiftUI
import SidetoneCore

public struct InspectorView: View {
    @Environment(AppState.self) private var state

    public init() {}

    public var body: some View {
        List {
            Section("Link") {
                if let lq = state.lastLinkQuality {
                    LinkQualityBar(quality: lq.quality)
                    Labeled("SNR", value: "\(lq.snr) dB")
                } else {
                    Text("No link data yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Session") {
                Labeled("State", value: describe(state.sessionState))
                Labeled("Buffer", value: "\(state.bufferBytes) bytes")
                HStack {
                    Text("PTT")
                    Spacer()
                    Circle()
                        .fill(state.ptt ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: 12, height: 12)
                        .animation(.easeInOut(duration: 0.1), value: state.ptt)
                }
                HStack {
                    Text("Channel")
                    Spacer()
                    Text(state.busy ? "BUSY" : "clear")
                        .foregroundStyle(state.busy ? .orange : .secondary)
                }
            }

            if let fault = state.lastFault {
                Section("Fault") {
                    Text(fault)
                        .foregroundStyle(.red)
                        .font(.callout.monospaced())
                }
            }
        }
        .navigationTitle("Inspector")
    }

    private func describe(_ s: SessionState) -> String {
        switch s {
        case .disconnected:
            return "Disconnected"
        case .listening:
            return "Listening"
        case .connecting(let peer, _):
            return "Connecting → \(peer.value)"
        case .connected(let peer, let bw, _):
            return "\(peer.value) @ \(bw) Hz"
        case .disconnecting:
            return "Disconnecting"
        case .error(let reason):
            return "Error: \(reason)"
        }
    }
}

struct LinkQualityBar: View {
    let quality: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Quality")
                Spacer()
                Text("\(quality)")
                    .font(.body.monospaced())
            }
            ProgressView(value: Double(max(0, min(100, quality))), total: 100)
                .tint(color)
        }
    }

    private var color: Color {
        switch quality {
        case ..<30: .red
        case 30..<60: .orange
        default: .green
        }
    }
}

struct Labeled: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
