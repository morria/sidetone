import SwiftUI
import UniformTypeIdentifiers
import SidetoneCore

/// Chronological activity log across all stations. Different from a
/// per-station transcript — this is the operator's "what happened
/// today" view, useful for logging a POTA session or finding a
/// conversation from last week.
public struct LogView: View {
    public let entries: [Message]
    public let myCall: Callsign?
    public let myGrid: SidetoneCore.Grid?
    @State private var adifDocument: ADIFDocument?

    public init(entries: [Message], myCall: Callsign? = nil, myGrid: SidetoneCore.Grid? = nil) {
        self.entries = entries
        self.myCall = myCall
        self.myGrid = myGrid
    }

    public var body: some View {
        List(entries) { entry in
            logRow(entry)
        }
        .navigationTitle("Activity log")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Messages you send and receive will show up here, newest first.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    let text = ADIFExporter(myCall: myCall, myGrid: myGrid).export(entries)
                    adifDocument = ADIFDocument(text: text)
                } label: {
                    Label("Export ADIF", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { adifDocument != nil },
                set: { if !$0 { adifDocument = nil } }
            ),
            document: adifDocument,
            contentType: .plainText,
            defaultFilename: "sidetone-log"
        ) { _ in
            adifDocument = nil
        }
    }

    private func logRow(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: message.direction))
                .foregroundStyle(color(for: message.direction))
                .font(.body.bold())
                .frame(width: 20)
                .accessibilityLabel(labelForDirection(message.direction))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.peer.value).font(.body.monospaced())
                    Spacer()
                    Text(message.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.body)
                    .font(.body.monospaced())
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for direction: Message.Direction) -> String {
        switch direction {
        case .sent:     "arrow.up.right"
        case .received: "arrow.down.left"
        case .system:   "info.circle"
        }
    }

    private func color(for direction: Message.Direction) -> Color {
        switch direction {
        case .sent:     .accentColor
        case .received: .green
        case .system:   .secondary
        }
    }

    private func labelForDirection(_ direction: Message.Direction) -> String {
        switch direction {
        case .sent:     "Sent"
        case .received: "Received"
        case .system:   "System message"
        }
    }
}

/// `FileDocument` carrying an ADIF export so SwiftUI's
/// `.fileExporter` can hand it to the system save panel.
struct ADIFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
