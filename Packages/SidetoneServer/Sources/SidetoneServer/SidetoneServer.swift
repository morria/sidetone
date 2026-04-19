import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import SidetoneCore

/// NIO-based HTTP/1.1 + WebSocket server. Binds a TCP socket (plaintext
/// for now — TLS + pairing come in M5e), dispatches HTTP requests
/// through `Router`, and upgrades `/api/v1/events` to WebSocket for
/// event streaming.
public final class SidetoneServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var tls: ServerTLS?

        public init(host: String = "0.0.0.0", port: Int = 0, tls: ServerTLS? = nil) {
            self.host = host
            self.port = port
            self.tls = tls
        }
    }

    /// PEM-encoded server cert + key. Normally produced by
    /// `CertificateManager.loadOrGenerate(...)` and held for the life
    /// of the server.
    public struct ServerTLS: Sendable {
        public var pemCertificate: String
        public var pemPrivateKey: String
        public init(pemCertificate: String, pemPrivateKey: String) {
            self.pemCertificate = pemCertificate
            self.pemPrivateKey = pemPrivateKey
        }
    }

    public enum ServerError: Error, Sendable {
        case notStarted
        case bindFailed(String)
    }

    private let host: ServerHost
    private let router: Router
    private let configuration: Configuration
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let broadcaster: WebSocketBroadcaster

    public init(configuration: Configuration = .init(), host serverHost: ServerHost, router: Router) {
        self.configuration = configuration
        self.host = serverHost
        self.router = router
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.broadcaster = WebSocketBroadcaster(host: serverHost)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// Bind and listen. Returns the real port (useful when configured
    /// with port 0 for ephemeral assignment in tests).
    public func start() async throws -> Int {
        let sslContext: NIOSSLContext? = try configuration.tls.map { tls in
            let cert = try NIOSSLCertificate(
                bytes: Array(tls.pemCertificate.utf8),
                format: .pem
            )
            let key = try NIOSSLPrivateKey(
                bytes: Array(tls.pemPrivateKey.utf8),
                format: .pem
            )
            var config = NIOSSL.TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(cert)],
                privateKey: .privateKey(key)
            )
            // ALPN is optional but useful — lets curl/browsers negotiate
            // h2 in the future. For now we only speak http/1.1.
            config.applicationProtocols = ["http/1.1"]
            return try NIOSSLContext(configuration: config)
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { [router, broadcaster] channel in
                Self.configurePipeline(
                    channel: channel,
                    router: router,
                    broadcaster: broadcaster,
                    sslContext: sslContext
                )
            }

        let bound: Channel
        do {
            bound = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
        channel = bound
        return bound.localAddress?.port ?? 0
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
        try? await group.shutdownGracefully()
    }

    public var broadcastingHost: ServerHost { host }

    private static func configurePipeline(
        channel: Channel,
        router: Router,
        broadcaster: WebSocketBroadcaster,
        sslContext: NIOSSLContext?
    ) -> EventLoopFuture<Void> {
        // We build the HTTP pipeline manually (instead of calling
        // `configureHTTPServerPipeline(withServerUpgrade:)`) so the
        // HTTPRequestDispatcher can be passed as `extraHTTPHandlers`
        // to `HTTPServerUpgradeHandler`. NIO then removes it
        // atomically alongside its own HTTP codec when an upgrade
        // succeeds — no race window where the dispatcher sees raw
        // WS frames as IOData.
        let tlsFuture: EventLoopFuture<Void> = {
            guard let sslContext else {
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            return channel.pipeline.addHandler(
                NIOSSLServerHandler(context: sslContext),
                position: .first
            )
        }()

        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let pipelineHandler = HTTPServerPipelineHandler()
        let dispatcher = HTTPRequestDispatcher(router: router)

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in
                if head.uri == "/api/v1/events" {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                return channel.eventLoop.makeSucceededFuture(nil)
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(
                    WebSocketConnectionHandler(broadcaster: broadcaster)
                )
            }
        )

        // The NIOWebSocketServerUpgrader above installs the WS frame
        // codec + our WebSocketConnectionHandler on successful upgrade.
        // This outer handler just needs to know which extra HTTP
        // handlers to remove alongside its own codec.
        let upgraders: [HTTPServerProtocolUpgrader] = [upgrader]
        let extraHandlers: [RemovableChannelHandler] = [pipelineHandler, dispatcher]
        let upgradeHandler = HTTPServerUpgradeHandler(
            upgraders: upgraders,
            httpEncoder: responseEncoder,
            extraHTTPHandlers: extraHandlers,
            upgradeCompletionHandler: { _ in }
        )

        return tlsFuture.flatMap {
            channel.pipeline.addHandlers(
                [responseEncoder, requestDecoder, pipelineHandler, upgradeHandler, dispatcher]
            )
        }
    }
}

/// Buffers a full HTTP request (head + body) and hands it to the
/// Router, then writes the Response back to the channel.
///
/// Streaming request bodies aren't meaningful for the /api/v1 surface
/// — every request is a small JSON blob — so we keep this simple and
/// accumulate the full body before dispatch.
final class HTTPRequestDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = nil
        case .body(var body):
            if bodyBuffer == nil {
                bodyBuffer = body
            } else {
                bodyBuffer?.writeBuffer(&body)
            }
        case .end:
            guard let head = requestHead else { return }
            let body: Data = {
                guard var buf = bodyBuffer else { return Data() }
                return Data(buf.readBytes(length: buf.readableBytes) ?? [])
            }()

            let (path, query) = splitPath(head.uri)
            let headers = Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) })
            let request = Request(
                method: head.method.rawValue,
                path: path,
                query: query,
                headers: headers,
                body: body
            )
            let channel = context.channel
            let router = self.router
            let keepAlive = head.isKeepAlive

            Task {
                do {
                    let response = try await router.dispatch(request)
                    await Self.write(response: response, to: channel, keepAlive: keepAlive)
                } catch {
                    let r = (try? Response.error(
                        "internal_error",
                        message: error.localizedDescription,
                        status: 500
                    )) ?? Response(status: 500)
                    await Self.write(response: r, to: channel, keepAlive: false)
                }
            }

            requestHead = nil
            bodyBuffer = nil
        }
    }

    private func splitPath(_ uri: String) -> (String, [String: String]) {
        guard let q = uri.firstIndex(of: "?") else { return (uri, [:]) }
        let path = String(uri[..<q])
        let queryString = uri[uri.index(after: q)...]
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                query[String(parts[0])] = String(parts[1])
            }
        }
        return (path, query)
    }

    private static func write(response: Response, to channel: Channel, keepAlive: Bool) async {
        var headers = HTTPHeaders()
        for (k, v) in response.headers {
            headers.add(name: k, value: v)
        }
        if headers["content-length"].isEmpty {
            headers.add(name: "Content-Length", value: String(response.body.count))
        }
        if !keepAlive { headers.add(name: "Connection", value: "close") }

        let head = HTTPResponseHead(
            version: .init(major: 1, minor: 1),
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )
        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)

        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        if !keepAlive {
            _ = try? await channel.close().get()
        }
    }
}
