import SwiftUI
import SidetoneCore

public struct ChatView: View {
    @Environment(AppState.self) private var state
    let peer: Callsign
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    public init(peer: Callsign) {
        self.peer = peer
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle(peer.value)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                let messages = state.transcripts[peer] ?? []
                ForEach(messages) { message in
                    MessageBubble(message: message)
                }
                if messages.isEmpty {
                    Text("No messages yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minHeight: 44, maxHeight: 160)
                .focused($composerFocused)

            HStack {
                Text("\(draft.count) chars")
                    .font(.caption.monospaced())
                    .foregroundStyle(draft.count > 512 ? .orange : .secondary)
                Spacer()
                Button("Ping") {
                    Task { try? await state.ping(peer) }
                }
                Button("Send") {
                    send()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { try? await state.send(body) }
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.direction == .sent { Spacer(minLength: 40) }
            VStack(alignment: alignment, spacing: 2) {
                Text(message.body)
                    .font(.body.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(background, in: .rect(cornerRadius: 10))
                HStack(spacing: 4) {
                    Text(message.peer.value)
                    Text("·")
                    Text(message.timestamp, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if message.direction == .received { Spacer(minLength: 40) }
        }
    }

    private var alignment: HorizontalAlignment {
        message.direction == .sent ? .trailing : .leading
    }

    private var background: Color {
        switch message.direction {
        case .sent:     Color.accentColor.opacity(0.2)
        case .received: Color.secondary.opacity(0.12)
        case .system:   Color.clear
        }
    }
}
