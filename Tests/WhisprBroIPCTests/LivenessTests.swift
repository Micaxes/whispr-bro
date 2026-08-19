import XCTest

@testable import WhisprBroIPC

/// The dual-condition dead-session verdict (`Liveness.sessionIsDead`): BOTH
/// ack-stale AND heartbeat-stale, never either alone.
final class LivenessTests: XCTestCase {
    private let now: UInt64 = 1_000_000

    func testBothStaleIsDead() {
        XCTAssertTrue(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - Liveness.commandAckTimeoutMillis - 1,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now - Liveness.audioHeartbeatTimeoutMillis - 1))
    }

    func testAckStaleAloneIsAliveButBusy() {
        // Model load starving non-control work: ack overdue, audio flowing.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - 10_000,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now - 50))
    }

    func testHeartbeatStaleAloneIsAlive() {
        // Arming / interruption teardown: no audio yet, but every command
        // acked promptly.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - 10_000,
            lastCommandAckSeq: 5,
            lastAudioCallbackAtMillis: now - 60_000))
    }

    func testPendingAckWithinTimeoutIsAlive() {
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - Liveness.commandAckTimeoutMillis + 1,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now - 60_000))
    }

    func testExactlyAtTimeoutsIsNotYetStale() {
        // "Over N ms ago" is strict on both conditions.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - Liveness.commandAckTimeoutMillis,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now - Liveness.audioHeartbeatTimeoutMillis))
        // One millisecond later both cross.
        XCTAssertTrue(Liveness.sessionIsDead(
            nowMillis: now + 1,
            lastPostedSeq: 5,
            lastPostedAtMillis: now - Liveness.commandAckTimeoutMillis,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now - Liveness.audioHeartbeatTimeoutMillis))
    }

    func testNothingPostedOrFullyAckedIsAlive() {
        // Never posted (seq 0): the ack condition can never hold.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 0,
            lastPostedAtMillis: 0,
            lastCommandAckSeq: 0,
            lastAudioCallbackAtMillis: now - 60_000))
        // Everything acked: same.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 3,
            lastPostedAtMillis: now - 10_000,
            lastCommandAckSeq: 3,
            lastAudioCallbackAtMillis: now - 60_000))
    }

    func testClockSkewNeverTraps() {
        // File timestamps ahead of the keyboard's clock (wall-clock skew
        // between stamps) must read as fresh, not underflow.
        XCTAssertFalse(Liveness.sessionIsDead(
            nowMillis: now,
            lastPostedSeq: 5,
            lastPostedAtMillis: now + 5_000,
            lastCommandAckSeq: 4,
            lastAudioCallbackAtMillis: now + 5_000))
    }
}
