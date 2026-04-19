import Foundation
import SidetoneCore

/// Converts a `SessionEvent` into an `APIv1.EventEnvelope` ready for
/// wire serialization. Kept separate from the host so the encoding
/// rules are testable without running NIO.
public enum EventSerializer {
    public static func envelope(for event: SessionEvent) -> APIv1.EventEnvelope? {
        do {
            switch event {
            case .stateChanged(let s):
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.stateChanged,
                    payload: APIv1.SessionStateDTO(s)
                )
            case .messageReceived(let m):
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.messageReceived,
                    payload: APIv1.MessageDTO(m)
                )
            case .messageSent(let m):
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.messageSent,
                    payload: APIv1.MessageDTO(m)
                )
            case .linkQuality(let snr, let q):
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.linkQuality,
                    payload: APIv1.LinkQualityEvent(snr: snr, quality: q)
                )
            case .ptt(let on):
                return try APIv1.EventEnvelope(kind: APIv1.EventKind.ptt, payload: APIv1.BoolEvent(on))
            case .busy(let on):
                return try APIv1.EventEnvelope(kind: APIv1.EventKind.busy, payload: APIv1.BoolEvent(on))
            case .buffer(let n):
                return try APIv1.EventEnvelope(kind: APIv1.EventKind.buffer, payload: APIv1.IntEvent(n))
            case .fault(let msg):
                return try APIv1.EventEnvelope(kind: APIv1.EventKind.fault, payload: APIv1.FaultEvent(msg))
            case .heard(let call, let grid):
                let station = APIv1.StationDTO(Station(callsign: call, grid: grid, lastHeard: Date()))
                return try APIv1.EventEnvelope(kind: APIv1.EventKind.heard, payload: station)
            case .fileProgress(let transfer):
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.fileProgress,
                    payload: APIv1.FileTransferDTO(transfer)
                )
            case .fileReceived(let transfer, _):
                // The payload bytes do NOT go over the WebSocket — they
                // land at a separate download endpoint keyed by id.
                return try APIv1.EventEnvelope(
                    kind: APIv1.EventKind.fileReceived,
                    payload: APIv1.FileTransferDTO(transfer)
                )
            }
        } catch {
            return nil
        }
    }

    public static func encode(_ envelope: APIv1.EventEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }
}
