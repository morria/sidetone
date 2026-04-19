import SwiftUI
import SidetoneCore

/// Top-level adaptive layout. `NavigationSplitView` gives us:
/// - three columns on Mac and iPad landscape,
/// - two columns on iPad portrait,
/// - stack navigation on iPhone.
/// Per spec: do not fight it. We pass a single `AppState` down the tree via
/// `@Environment` so every view reads the same source of truth.
public struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var selectedPeer: Callsign?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedPeer)
        } content: {
            if let peer = selectedPeer {
                ChatView(peer: peer)
            } else {
                EmptyChatPlaceholder()
            }
        } detail: {
            InspectorView()
        }
    }
}

struct EmptyChatPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "No station selected",
            systemImage: "antenna.radiowaves.left.and.right",
            description: Text("Pick a station from the sidebar, or add a new one to get started.")
        )
    }
}
