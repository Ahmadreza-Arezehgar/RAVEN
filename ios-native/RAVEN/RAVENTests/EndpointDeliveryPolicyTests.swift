//
//  EndpointDeliveryPolicyTests.swift
//  RAVENTests — Phase B: write success is FORWARDED, not DELIVERED_TO_DEVICE.
//

import XCTest
@testable import RAVEN

final class EndpointDeliveryPolicyTests: XCTestCase {

    func testTransportWriteSuccessIsNotProtocolDelivered() {
        XCTAssertEqual(EndpointDeliveryPolicy.messageStatusAfterTransportWrite(), .sent)
        XCTAssertNotEqual(EndpointDeliveryPolicy.messageStatusAfterTransportWrite(), .delivered)
        XCTAssertNotEqual(EndpointDeliveryPolicy.messageStatusAfterTransportWrite(), .read)

        XCTAssertEqual(EndpointDeliveryPolicy.jobStateAfterTransportWrite(), .transmitted)
        XCTAssertEqual(JobState.transmitted.rawValue, "transmitted")
        XCTAssertNotEqual(JobState.transmitted.rawValue, "delivered")
    }

    func testPerChannelTransmittedNeverMapsToDeliveredBadge() {
        XCTAssertEqual(
            EndpointDeliveryPolicy.protocolStatus(fromJobState: .transmitted),
            .sent,
            "JobState.transmitted is FORWARDED; UI must not show Delivered"
        )
        XCTAssertNotEqual(
            EndpointDeliveryPolicy.protocolStatus(fromJobState: .transmitted),
            .delivered
        )
        XCTAssertNotEqual(
            EndpointDeliveryPolicy.protocolStatus(fromJobState: .transmitted),
            .read
        )
        XCTAssertEqual(JobState.parse("delivered"), .transmitted)
        XCTAssertEqual(JobState.parse("transmitted"), .transmitted)
    }

    func testVerifiedAckStatus1IsDeliveredAndStatus2IsRead() {
        XCTAssertEqual(RavenAckV1.deliveredStatus, 1)
        XCTAssertEqual(RavenAckV1.readStatus, 2)
        XCTAssertEqual(
            EndpointDeliveryPolicy.afterVerifiedAck(status: RavenAckV1.deliveredStatus),
            .delivered
        )
        XCTAssertEqual(
            EndpointDeliveryPolicy.afterVerifiedAck(status: RavenAckV1.readStatus),
            .read
        )
        XCTAssertNil(EndpointDeliveryPolicy.afterVerifiedAck(status: 0))
        XCTAssertNil(EndpointDeliveryPolicy.afterVerifiedAck(status: 3))
    }

    func testWriteSuccessDoesNotAdvanceLikeVerifiedAck() {
        let afterWrite = EndpointDeliveryPolicy.messageStatusAfterTransportWrite()
        let afterAck = EndpointDeliveryPolicy.afterVerifiedAck(status: RavenAckV1.deliveredStatus)
        XCTAssertNotEqual(afterWrite, afterAck)
        XCTAssertTrue(MeshACKHandler.statusAdvances(from: afterWrite, to: .delivered))
        XCTAssertFalse(MeshACKHandler.statusAdvances(from: .delivered, to: afterWrite))
    }
}
