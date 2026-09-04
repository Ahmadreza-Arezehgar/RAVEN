//
//  EndpointDeliveryPolicy.swift
//  RAVEN
//
//  Binding mapping for RAVEN_ACK_V1 §3 / RAVEN_DELIVERY_STATE_V1:
//  transport write success is FORWARDED only; DELIVERED_TO_DEVICE / READ
//  require a verified sealed env_type=2 ACK. Wire bytes are unchanged.
//

import Foundation

/// Local endpoint delivery transitions. Does not encode or decode wire ACKs.
enum EndpointDeliveryPolicy {
    /// Transport write / HTTP 2xx / BLE or libp2p stream success.
    /// Logical FORWARDED (`DeliveryState::Sent`), never `DELIVERED_TO_DEVICE`.
    static func messageStatusAfterTransportWrite() -> MessageStatus {
        .sent
    }

    /// Per-channel job bookkeeping after a local send or a channel taken
    /// out of rotation. Never protocol Delivered.
    static func jobStateAfterTransportWrite() -> JobState {
        .transmitted
    }

    /// Verified sealed `RavenAckV1` status byte after decrypt + device-key verify
    /// and exact `acked_message_id` binding. `status=1` → Delivered, `status=2` → Read.
    static func afterVerifiedAck(status: UInt8) -> MessageStatus? {
        switch status {
        case RavenAckV1.deliveredStatus:
            return .delivered
        case RavenAckV1.readStatus:
            return .read
        default:
            return nil
        }
    }

    /// UI / protocol status implied by per-channel job bookkeeping.
    /// `JobState.transmitted` is Sent (FORWARDED), never Delivered.
    static func protocolStatus(fromJobState state: JobState) -> MessageStatus? {
        state.protocolMessageStatus
    }
}
