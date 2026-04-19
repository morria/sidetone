import Foundation
import os
import NIOCore
import NIOWebSocket
import SidetoneCore

/// Owns the set of active WebSocket connections and shovels every
/// `SessionEvent` to all of them as JSON envelopes.
///
/// Lives for the lifetime of the server. Individual
/// `WebSocketConnectionHandler`s register on upgrade and deregister on
/// close. The broadcaster subscribes once to the `ServerHost`'s event
/// stream and fans out; per-client subscriptions would be nicer but
/// the multi-op semantics aren't decided yet, so single-fanout is
/// fine for now.
final class WebSocketBroadcaster: @unchecked Sendable {
    private struct State {
        var channels: [ObjectIdentifier: Channel] = [:]
        var pumpStarted = false
        var subscriptionID: UUID?
    }

    private let host: ServerHost
    // `OSAllocatedUnfairLock` is the async-safe replacement for NSLock
    // in Swift 6. It stays briefly held for bookkeeping only.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(host: ServerHost) {
        self.host = host
    }

    func register(_ channel: Channel) {
        let needsPump = state.withLock { state -> Bool in
            state.channels[ObjectIdentifier(channel)] = channel
            let fresh = !state.pumpStarted
            state.pumpStarted = true
            return fresh
        }
        if needsPump {
            Task { [weak self] in await self?.startPump() }
        }
    }

    func deregister(_ channel: Channel) {
        state.withLock { state in
            _ = state.channels.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    private func startPump() async {
        await host.start()
        let id = await host.subscribe { [weak self] event in
            guard let self else { return }
            guard let envelope = EventSerializer.envelope(for: event),
                  let data = try? EventSerializer.encode(envelope) else { return }
            self.broadcast(data)
        }
        state.withLock { state in state.subscriptionID = id }
    }

    private func broadcast(_ data: Data) {
        let snapshot: [Channel] = state.withLock { state in Array(state.channels.values) }
        for channel in snapshot {
            guard channel.isActive else { continue }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            _ = channel.writeAndFlush(frame)
        }
    }
}

/// Installed at the end of the pipeline after upgrade. Registers with
/// the broadcaster on activation, deregisters on close, handles ping
/// and close frames.
final class WebSocketConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let broadcaster: WebSocketBroadcaster

    init(broadcaster: WebSocketBroadcaster) {
        self.broadcaster = broadcaster
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // The WS handler is installed *after* upgrade on an already-
        // active channel — so `channelActive` won't fire again. Register
        // on `handlerAdded` instead so the broadcaster starts pumping
        // events to this client immediately.
        broadcaster.register(context.channel)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        broadcaster.deregister(context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        broadcaster.deregister(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            var pong = frame
            pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
