import Foundation
import Network

/// Advertises the Sidetone server over Bonjour so iOS/iPad clients on
/// the same LAN can discover it without typing an IP address.
///
/// The advertisement is a thin wrapper around `NWListener`'s
/// `service` property — we don't actually want to terminate
/// connections here (NIO handles that on a different listener). We
/// create a *separate* loopback listener purely for publishing the
/// service record, then point clients at the real NIO server's port
/// via the TXT record.
///
/// That indirection is needed because NIO's server (a `ServerBootstrap`
/// over `ServerSocketChannel`) doesn't expose an NWListener we could
/// advertise directly. The cost is one extra socket; the benefit is a
/// tidy Bonjour hook without rewriting the HTTP layer.
public final class BonjourAdvertiser: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var serviceType: String
        public var serviceName: String
        public var port: UInt16
        public var txtRecord: [String: String]

        public init(serviceType: String = BonjourBrowser.serviceType, serviceName: String, port: UInt16, txtRecord: [String: String] = [:]) {
            self.serviceType = serviceType
            self.serviceName = serviceName
            self.port = port
            self.txtRecord = txtRecord
        }
    }

    private let configuration: Configuration
    private var listener: NWListener?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func start() throws {
        var entries = configuration.txtRecord
        entries["port"] = String(configuration.port)
        let txt = NWTXTRecord(entries)

        let params = NWParameters.tcp
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(
            name: configuration.serviceName,
            type: configuration.serviceType,
            domain: nil,
            txtRecord: txt
        )
        // We don't intend to accept connections here, but NWListener
        // requires a handler. Close anything that comes in; the real
        // HTTP server lives on a different port per the TXT record.
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
