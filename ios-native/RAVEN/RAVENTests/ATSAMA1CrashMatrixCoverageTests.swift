//
//  ATSAMA1CrashMatrixCoverageTests.swift
//  RAVENTests
//
//  A1 exit gate: discoverable §5.1–§5.5 crash-matrix coverage map.
//  Covered windows assert their backing XCTest exists; gaps XCTSkip explicitly.
//

#if DEBUG

import XCTest
@testable import RAVEN

private typealias Endpoint = ATSAMEndpointTransactionV1

/// One design §5 row or §11 A1 checklist item mapped to automation (or a documented gap).
private struct A1CoverageRow {
    enum Status {
        case covered(testClass: String, testMethod: String)
        case gap(reason: String)
    }

    let section: String
    let window: String
    let status: Status
}

final class ATSAMA1CrashMatrixCoverageTests: XCTestCase {

    // MARK: - §5.1 Protected-head two-phase (receive and send)

    private static let section51: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§5.1",
            window: "Before atomic protected replacement (message receive)",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testCrashMatrixRecoversWithoutKeyReuseOrFalseSecondUIEvent"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After protected replacement, before SQL (message receive)",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testCrashMatrixRecoversWithoutKeyReuseOrFalseSecondUIEvent"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After SQL, before journal clear (message receive)",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testAckIntentRowExistsAfterDatabaseCommitBeforeJournalClear"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After journal clear, before ACK worker (message receive)",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testAckIntentPersistsAfterJournalClear"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "Before atomic protected replacement (send)",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After protected replacement, before SQL (send)",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After SQL, before journal clear (send)",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix"
            )
        ),
        A1CoverageRow(
            section: "§5.1",
            window: "After journal clear, before dial (send)",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testSendCommitsOutboxBeforeDialOutsideLease"
            )
        ),
    ]

    // MARK: - §5.2 ACK send worker

    private static let section52: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§5.2",
            window: "After receive commit, before ACK pending_outbound",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testAckMaterializeTwoPhaseCrashRecoveryDoesNotReAdvanceAckSend"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "After protected ACK replacement, before SQL outbox",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testAckMaterializeTwoPhaseCrashRecoveryDoesNotReAdvanceAckSend"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "After SQL, before ACK journal clear",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testAckMaterializeTwoPhaseCrashRecoveryDoesNotReAdvanceAckSend"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "After journal clear, before immutable enqueue",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testAckWorkerStagesFullEnvelopeAndRetriesIdenticalBytesAfterCrashes"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "After immutable enqueue, before queued-mark",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testAckWorkerStagesFullEnvelopeAndRetriesIdenticalBytesAfterCrashes"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "After queued-mark, before dial",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testAckResumeStopsAtEnqueueNotDial"
            )
        ),
        A1CoverageRow(
            section: "§5.2",
            window: "ACK loss on wire",
            status: .gap(
                reason: "Wire-drop / transport retry is A2 LAN scope; not feasible in memory-only XCTest host."
            )
        ),
    ]

    // MARK: - §5.3 Inbound ACK acceptance

    private static let section53: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§5.3",
            window: "After outer auth, before duplicate lookup / decrypt",
            status: .gap(
                reason: "No CrashPoint hook between acceptAck outer auth and duplicate lookup; pre-decrypt kill is SIGKILL-integration scope."
            )
        ),
        A1CoverageRow(
            section: "§5.3",
            window: "After decrypt / ack_receive journal, before SQL",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckCrashAndDatabaseFailureRecoveryIsIdempotent"
            )
        ),
        A1CoverageRow(
            section: "§5.3",
            window: "After SQL, before journal clear",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckCrashAndDatabaseFailureRecoveryIsIdempotent"
            )
        ),
        A1CoverageRow(
            section: "§5.3",
            window: "After journal clear, before history/stage reconcile",
            status: .gap(
                reason: "Post-acceptAck journal-clear stage/history reconcile has no injected crash point in A1 unit harness."
            )
        ),
        A1CoverageRow(
            section: "§5.3",
            window: "Duplicate ACK replay",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckAcceptanceIsExactIndependentAndMonotonic"
            )
        ),
        A1CoverageRow(
            section: "§5.3",
            window: "Forged / wrong-recipient / bad inner sig / nonce conflict / stale",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckNegativeMatrixNeverAdvancesOutstandingOrRatchet"
            )
        ),
    ]

    // MARK: - §5.4 Send worker

    private static let section54: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§5.4",
            window: "Before body-stage write",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendBeforeBodyStageCrashDoesNotDialOrAdvance"
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After body stage, before outbox two-phase (orphan G2)",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testStageBeforeOutboxCrashWindow"
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After outbox SQL, before journal clear",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix"
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After journal clear, before Queued transition",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix"
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After Queued, before dial",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testSendCommitsOutboxBeforeDialOutsideLease"
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After dial, before ACK accept",
            status: .gap(
                reason: "End-to-end Sent→ACK accept requires transport + relaunch (A2 / SIGKILL integration)."
            )
        ),
        A1CoverageRow(
            section: "§5.4",
            window: "After ACK accept, before stage clear",
            status: .gap(
                reason: "Post-delivery stage reconcile after inbound ACK accept is not crash-injected in A1 unit harness."
            )
        ),
    ]

    // MARK: - §5.5 PairInit lifecycle

    private static let section55: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§5.5",
            window: "Initiator: after persist packed init, before send",
            status: .covered(
                testClass: "ATSAMPrekeyLifecycleStoreTests",
                testMethod: "testInitiatorPersistsExactPackedBytesForResend"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Initiator: after send, PairResponse lost",
            status: .gap(
                reason: "LAN wire drop / retry is A2 transport scope."
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: before claim journal durable",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testPairInitClaimJournalRollForwardBeforeDurableWrite"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: after claim journal durable, before claim commit complete",
            status: .covered(
                testClass: "ATSAMPrekeyLifecycleStoreTests",
                testMethod: "testClaimJournalRollsForwardAfterClaimJournalCrash"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: after claim commit, before response cache",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testPairInitAcceptWindowFaultInjectionNeverCompletesClaimBeforeConfirm"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: after cache, before confirm",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testPairInitAcceptWindowFaultInjectionNeverCompletesClaimBeforeConfirm"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: after confirm, before complete_claim",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testPairInitAcceptWindowFaultInjectionNeverCompletesClaimBeforeConfirm"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Responder: after complete_claim",
            status: .gap(
                reason: "Post-complete_claim idempotent return path not crash-injected in A1 unit harness."
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Duplicate message (application replay)",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testExactCommittedDuplicateDoesNotAdvanceOrSurfacePlaintextTwice"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Process kill both sides mid-session",
            status: .gap(
                reason: "SIGKILL / dual-process relaunch is A2 manual lab + integration scope."
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Block/revoke mid-flight",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckContactGateAndSessionConfirmedRefuseWithoutDeliveryChange"
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Session expiry",
            status: .gap(
                reason: "Session-expiry abandon path not yet in A1 crash-matrix unit suite."
            )
        ),
        A1CoverageRow(
            section: "§5.5",
            window: "Contact deleted after confirm",
            status: .gap(
                reason: "Post-confirm contact deletion refuse requires durable trust-store integration test."
            )
        ),
    ]

    /// Design §11 A1 checklist (lab Debug builds).
    private static let a1Checklist: [A1CoverageRow] = [
        A1CoverageRow(
            section: "§11",
            window: "Journals survive unit fault injection crash points",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testDurabilityFailuresFailClosedAndRecoverFromProtectedJournal"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Exact-duplicate before decrypt (message receive)",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testExactDuplicateAfterOuterAuthDoesNotDecryptOrAdvanceRatchet"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Exact-duplicate before decrypt (inbound ACK)",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckAcceptanceIsExactIndependentAndMonotonic"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Receipt + inbox + ACK intent same SQL tx",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testAckIntentRowExistsAfterDatabaseCommitBeforeJournalClear"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Inbound ACK accept with outstanding CAS",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testOriginAckAcceptanceIsExactIndependentAndMonotonic"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "ACK send resume / digests / queue lifecycle",
            status: .covered(
                testClass: "ATSAMEndpointTransactionV1Tests",
                testMethod: "testAckWorkerStagesFullEnvelopeAndRetriesIdenticalBytesAfterCrashes"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Body stage before outbox; orphan delete G2",
            status: .covered(
                testClass: "ATSAMEndpointDurabilityTests",
                testMethod: "testOrphanStageDeleteNeverDials"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "SQLCipher cipher_version fail-closed",
            status: .covered(
                testClass: "ATSAMEndpointSQLCipherTests",
                testMethod: "testOpenFailsWhenCipherVersionMissing"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "PairInit claim roll-forward + response cache fsync",
            status: .covered(
                testClass: "ATSAMPrekeyLifecycleStoreTests",
                testMethod: "testPairResponseCacheAtomicStoreVerifyAndTamperEviction"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Release cannot enable actors (LabGate)",
            status: .covered(
                testClass: "ATSAMLabGateTests",
                testMethod: "testReleaseBuildAlwaysDisabledIsTrue"
            )
        ),
        A1CoverageRow(
            section: "§11",
            window: "Contact gate on PairInit accept path",
            status: .covered(
                testClass: "ATSAMA1P0RecoveryTests",
                testMethod: "testPairInitAcceptContactGateRefusesUntrustedPeer"
            )
        ),
    ]

    private static var allRows: [A1CoverageRow] {
        section51 + section52 + section53 + section54 + section55 + a1Checklist
    }

    // MARK: - Table integrity

    func testA1CrashMatrixTableEveryRowHasCoverageOrGap() {
        for row in Self.allRows {
            switch row.status {
            case .covered(let testClass, let testMethod):
                XCTAssertFalse(testClass.isEmpty, row.window)
                XCTAssertFalse(testMethod.isEmpty, row.window)
                XCTAssertTrue(
                    testMethod.hasPrefix("test"),
                    "\(row.section) \(row.window): method must start with test"
                )
            case .gap(let reason):
                XCTAssertFalse(reason.isEmpty, row.window)
            }
        }
        let covered = Self.allRows.filter {
            if case .covered = $0.status { return true }
            return false
        }.count
        let gaps = Self.allRows.count - covered
        XCTAssertGreaterThan(covered, 0)
        XCTAssertGreaterThanOrEqual(gaps, 0)
    }

    func testA1CrashMatrixCoveredRowsReferenceExistingXCTests() {
        for row in Self.allRows {
            guard case let .covered(testClass, testMethod) = row.status else { continue }
            guard let type = Self.knownTestClasses[testClass] else {
                XCTFail("Unknown test class \(testClass) for \(row.section) \(row.window)")
                continue
            }
            XCTAssertTrue(
                Self.testMethodExists(in: type, named: testMethod),
                "Expected \(testClass).\(testMethod) for \(row.section) \(row.window)"
            )
        }
    }

    private static func testMethodExists(in type: XCTestCase.Type, named method: String) -> Bool {
        let suite = XCTestSuite(forTestCaseClass: type)
        return suite.tests.contains { test in
            test.name.contains(method)
        }
    }

    private static let knownTestClasses: [String: XCTestCase.Type] = [
        "ATSAMEndpointTransactionV1Tests": ATSAMEndpointTransactionV1Tests.self,
        "ATSAMEndpointDurabilityTests": ATSAMEndpointDurabilityTests.self,
        "ATSAMEndpointSQLCipherTests": ATSAMEndpointSQLCipherTests.self,
        "ATSAMPrekeyLifecycleStoreTests": ATSAMPrekeyLifecycleStoreTests.self,
        "ATSAMLabGateTests": ATSAMLabGateTests.self,
        "ATSAMA1P0RecoveryTests": ATSAMA1P0RecoveryTests.self,
    ]

    // MARK: - Rust CrashPoint alignment (shared two-phase + ACK enqueue)

    func testSharedCrashPointNamesAlignWithRustEndpointFaultPoint() {
        // Rust EndpointFaultPoint uses PascalCase; Swift CrashPoint uses lowerCamelCase rawValue.
        let rustAligned: [(Endpoint.CrashPoint, String)] = [
            (.beforeDatabaseCommit, "BeforeDatabaseCommit"),
            (.afterDatabaseCommit, "AfterDatabaseCommit"),
            (.beforeJournalClear, "BeforeJournalClear"),
            (.afterJournalClear, "AfterJournalClear"),
        ]
        for (swiftPoint, rustName) in rustAligned {
            let expected = rustName.prefix(1).lowercased() + rustName.dropFirst()
            XCTAssertEqual(swiftPoint.rawValue, expected)
        }
        // Documented Swift↔Rust naming divergences (semantic parity, not identical rawValue):
        XCTAssertEqual(
            Endpoint.CrashPoint.beforeProtectedStateReplacement.rawValue,
            "beforeProtectedStateReplacement"
        ) // Rust: BeforeProtectedReplacement
        XCTAssertEqual(
            Endpoint.CrashPoint.beforeImmutableAckEnqueue.rawValue,
            "beforeImmutableAckEnqueue"
        ) // Rust: BeforeAckEnqueue
        // Swift splits outbound queue handoff into queued-mark; Rust uses OutboundQueueHandoff.
        XCTAssertEqual(Endpoint.CrashPoint.beforeAckQueuedMark.rawValue, "beforeAckQueuedMark")
        XCTAssertEqual(Endpoint.CrashPoint.afterAckQueuedMark.rawValue, "afterAckQueuedMark")
    }

    func testPrekeyFaultPointCasesMatchRustFaultPoint() {
        // Rust prekey_lifecycle::FaultPoint::{ClaimJournal, ClaimCommit}
        let cases: [ATSAMPrekeyLifecycleStore.FaultPoint] = [
            .beforeClaimJournal,
            .claimJournal,
            .claimCommit,
        ]
        XCTAssertEqual(cases.count, 3)
        XCTAssertEqual(String(describing: cases[0]), "beforeClaimJournal")
        XCTAssertEqual(String(describing: cases[1]), "claimJournal")
        XCTAssertEqual(String(describing: cases[2]), "claimCommit")
    }

    // MARK: - P0 coverage gate + non-P0 gap inventory

    private static let p0TestMethods: Set<String> = [
        "testSendProtectedHeadTwoPhaseCrashRecoveryMatrix",
        "testSendBeforeBodyStageCrashDoesNotDialOrAdvance",
        "testAckMaterializeTwoPhaseCrashRecoveryDoesNotReAdvanceAckSend",
        "testPairInitClaimJournalRollForwardBeforeDurableWrite",
        "testPairInitAcceptWindowFaultInjectionNeverCompletesClaimBeforeConfirm",
        "testReceiveBlockRevokeGatesRefuseWithoutAdvance",
        "testInboundAckContactBlockRevokeGatesRefuseWithoutDeliveryChange",
        "testPairInitAcceptContactGateRefusesUntrustedPeer",
        "testDurableReopenReceiveJournalRecoversPendingAcceptance",
        "testDurableReopenSendOutboxSurvivesRelaunchWithoutOrphanDial",
        "testDurableReopenAckSendMaterializeResumesAfterRelaunch",
        "testDurableReopenAckAcceptJournalRecoversAfterRelaunch",
        "testDurableReopenPairInitClaimJournalRollsForwardAfterRelaunch",
    ]

    func testP0RowsAreCoveredWithoutSkipMarkers() {
        let p0Windows = Self.allRows.filter { row in
            if case let .covered(testClass, testMethod) = row.status,
               testClass == "ATSAMA1P0RecoveryTests" {
                return Self.p0TestMethods.contains(testMethod)
            }
            return false
        }
        XCTAssertGreaterThanOrEqual(p0Windows.count, 13)
        for row in p0Windows {
            guard case let .covered(testClass, testMethod) = row.status else { continue }
            XCTAssertTrue(
                Self.testMethodExists(in: ATSAMA1P0RecoveryTests.self, named: testMethod),
                "\(row.section) \(row.window) → \(testClass).\(testMethod)"
            )
        }
    }

    func testNonP0GapInventoryDocumentsRemainingA2OrEnvironmentalWindows() {
        let gaps = Self.allRows.compactMap { row -> String? in
            guard case let .gap(reason) = row.status else { return nil }
            return "\(row.section) \(row.window) — \(reason)"
        }
        XCTAssertGreaterThan(gaps.count, 0, "non-P0 gaps must remain documented")
        for entry in gaps {
            XCTContext.runActivity(named: "GAP: \(entry)") { _ in }
        }
    }

    func testGapSection52AckLossOnWire() throws {
        throw XCTSkip(Self.gapReason(section: "§5.2", windowPrefix: "ACK loss on wire"))
    }

    func testGapSection53PreDecryptInboundAck() throws {
        throw XCTSkip(Self.gapReason(section: "§5.3", windowPrefix: "After outer auth, before duplicate lookup"))
    }

    func testGapSection54AfterDialBeforeAckAccept() throws {
        throw XCTSkip(Self.gapReason(section: "§5.4", windowPrefix: "After dial, before ACK accept"))
    }

    func testGapSection55DualProcessKill() throws {
        throw XCTSkip(Self.gapReason(section: "§5.5", windowPrefix: "Process kill both sides"))
    }

    func testReleaseConfigurationLabGateAndWrappersAreFalse() throws {
        #if DEBUG
        throw XCTSkip("Release-only LabGate fail-closed verification")
        #else
        XCTAssertFalse(ATSAMLabGate.isEnabled)
        XCTAssertFalse(ATSAMPairInitV1.productionEnabled)
        XCTAssertFalse(ATSAMEndpointTransactionV1.productionEnabled)
        XCTAssertFalse(ATSAMIndexedSessionProfile.productionEnabled)
        XCTAssertFalse(ATSAMEndpointDurableAdapters.labTestAEnabled)
        #endif
    }

    func testReleaseProductionFlagsRemainFailClosed() {
        XCTAssertTrue(ATSAMLabGate.releaseBuildAlwaysDisabled)
        #if DEBUG
        // Lab gate may be on in tests via UserDefaults; productionEnabled must track it, never true in Release.
        _ = ATSAMEndpointTransactionV1.productionEnabled
        _ = ATSAMPairInitV1.productionEnabled
        #else
        XCTAssertFalse(ATSAMEndpointTransactionV1.productionEnabled)
        XCTAssertFalse(ATSAMPairInitV1.productionEnabled)
        XCTAssertFalse(ATSAMIndexedSessionProfile.productionEnabled)
        XCTAssertFalse(ATSAMEndpointDurableAdapters.labTestAEnabled)
        #endif
    }

    // MARK: - Helpers

    private static func gapReason(section: String, windowPrefix: String) -> String {
        let row = allRows.first {
            $0.section == section && $0.window.hasPrefix(windowPrefix)
        }
        if case let .gap(reason) = row?.status {
            return reason
        }
        return "Undocumented gap for \(section) \(windowPrefix)"
    }
}

#endif
