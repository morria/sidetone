import Foundation
import Network

/// Discovers Sidetone servers on the local network via Bonjour
/// (`_sidetone._tcp`). Used by iOS/iPad (and the Mac client-mode flow)
/// to populate the setup screen with one-tap server picks.
///
/// Emits an `AsyncStream<[DiscoveredServer]>` that yields the current
/// list whenever it changes. The list is deduplicated by endpoint.
/// Each server carries its name, hostname, port, and any TXT-record
/// metadata (fingerprint hint for trust-on-first-use, etc.).
public final class BonjourBrowser: @unchecked Sendable {
    public struct DiscoveredServer: Hashable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let host: String?
        public let port: UInt16?
        public let metadata: [String: String]

        public init(name: String, host: String?, port: UInt16?, metadata: [String: String] = [:]) {
            self.name = name
            self.host = host
            self.port = port
            self.metadata = metadata
        }
    }

    public static let serviceType = "_sidetone._tcp"

    public nonisolated let servers: AsyncStream<[DiscoveredServer]>
    private nonisolated let continuation: AsyncStream<[DiscoveredServer]>.Continuation
    private let browser: NWBrowser

    public init(serviceType: String = "_sidetone._tcp") {
        (servers, continuation) = AsyncStream.makeStream(of: [DiscoveredServer].self)
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
        self.browser = NWBrowser(for: descriptor, using: .tcp)

        browser.browseResultsChangedHandler = { [continuation] results, _ in
            let discovered = results.compactMap { result -> DiscoveredServer? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }

                var metadata: [String: String] = [:]
                if case let .bonjour(txtRecord) = result.metadata {
                    metadata = txtRecord.dictionary ?? [:]
                }

                // NWBrowser gives us the service; resolving to a concrete
                // host/port requires an NWConnection. Leave those nil here;
                // a connecting client can resolve via `NWConnection(to:)`
                // with the full endpoint.
                return DiscoveredServer(name: name, host: nil, port: nil, metadata: metadata)
            }
            continuation.yield(discovered)
        }
    }

    deinit {
        continuation.finish()
        browser.cancel()
    }

    public func start() {
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser.cancel()
        continuation.finish()
    }
}

