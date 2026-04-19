import SwiftUI
import SidetoneCore
import UniformTypeIdentifiers

public struct ChatView: View {
    @Environment(AppState.self) private var state
    let peer: Callsign
    @State private var draft = ""
    @State private var showingFilePicker = false
    @State private var fileSendError: String?
    @FocusState private var composerFocused: Bool

    public init(peer: Callsign) {
        self.peer = peer
    }

    public var body: some View {
        VStack(spacing: 0) {
            inFlightTransfersBanner
            transcript
            Divider()
            composer
        }
        .navigationTitle(peer.value)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        .alert("Couldn't send file", isPresented: .constant(fileSendError != nil)) {
            Button("OK") { fileSendError = nil }
        } message: {
            Text(fileSendError ?? "")
        }
    }

    @ViewBuilder
    private var inFlightTransfersBanner: some View {
        let transfers = state.fileTransfers.values.filter { $0.peer == peer && !$0.isComplete }
        if !transfers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(transfers), id: \.id) { transfer in
                    HStack {
                        Image(systemName: transfer.direction == .outbound ? "arrow.up.doc" : "arrow.down.doc")
                        Text(transfer.filename).font(.caption.monospaced())
                        Spacer()
                        ProgressView(value: transfer.progress)
                            .frame(width: 120)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            if data.count > 512 * 1024 {
                fileSendError = "File is \(data.count / 1024) KB. Over HF that will take a long time to send; split or shrink before attaching."
                return
            }
            let filename = url.lastPathComponent
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            Task { try? await state.sendFile(data: data, filename: filename, mimeType: mime) }
        } catch {
            fileSendError = error.localizedDescription
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                let messages = state.transcripts[peer] ?? []
                ForEach(messages) { message in
                    MessageBubble(message: message)
                }
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label("No messages", systemImage: "text.bubble")
                    } description: {
                        Text("When \(peer.value) answers, their traffic will appear here.")
                    }
                    .frame(maxWidth: .infinity)
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
                    .accessibilityLabel("\(draft.count) characters typed")
                Spacer()
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .accessibilityHint("Attach and send a file to \(peer.value)")
                Button("Ping") {
                    Task { try? await state.ping(peer) }
                }
                .accessibilityHint("Send a link-quality ping to \(peer.value)")
                Button("Send") {
                    send()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("Send the composed message on the air")
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
