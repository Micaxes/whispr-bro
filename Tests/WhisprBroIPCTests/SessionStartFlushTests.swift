import XCTest

@testable import WhisprBroIPC

/// The bring-up flush partition: which mailbox records survive a session
/// start (`SessionIPC.begin` preserving a keyboard-armed session's own
/// pre-posted startDictation) and which are discarded as stale.
final class SessionStartFlushTests: XCTestCase {
    private let now: UInt64 = 1_000_000

    private func record(
        seq: UInt32, _ command: KeyboardCommand, issuedAtMillis: UInt64
    ) -> CommandRecord {
        CommandRecord(
            seq: seq, command: command, requestUUID: UUID(),
            keyboardInstanceNonce: UUID(), issuedAtMillis: issuedAtMillis)
    }

    func testYoungStartIsPreserved() {
        let start = record(seq: 1, .startDictation, issuedAtMillis: now - 500)
        let (preserved, discarded) = SessionStartFlush.partition([start], nowMillis: now)
        XCTAssertEqual(preserved, [start])
        XCTAssertEqual(discarded, [])
    }

    func testStartOlderThanCeilingIsDiscarded() {
        let fossil = record(
            seq: 1, .startDictation,
            issuedAtMillis: now - SessionStartFlush.preservedStartMaxAgeMillis - 1)
        let (preserved, discarded) = SessionStartFlush.partition([fossil], nowMillis: now)
        XCTAssertEqual(preserved, [])
        XCTAssertEqual(discarded, [fossil])
    }

    func testExactBoundaryAgeIsPreserved() {
        // "Older than" is strict, mirroring Liveness: age == ceiling is not
        // yet over it.
        let boundary = record(
            seq: 1, .startDictation,
            issuedAtMillis: now - SessionStartFlush.preservedStartMaxAgeMillis)
        let (preserved, discarded) = SessionStartFlush.partition([boundary], nowMillis: now)
        XCTAssertEqual(preserved, [boundary])
        XCTAssertEqual(discarded, [])
    }

    func testNonStartCommandsAreDiscardedAtAnyAge() {
        let records = [
            record(seq: 1, .stopDictation, issuedAtMillis: now), // brand new
            record(seq: 2, .cancel, issuedAtMillis: now - 100),
            record(seq: 3, .killSession, issuedAtMillis: now - 50_000),
        ]
        let (preserved, discarded) = SessionStartFlush.partition(records, nowMillis: now)
        XCTAssertEqual(preserved, [])
        XCTAssertEqual(discarded, records)
    }

    func testMixedBatchPreservesOnlyTheNewestYoungStart() {
        // Two young starts in one flush = one is an orphan (a jetsammed
        // prior session's never-drained arming tap). Only the newest — the
        // tap that armed THIS session — may survive; delivering the orphan
        // would key segment 1 to a dead keyboard's nonce.
        let oldStart = record(seq: 1, .startDictation, issuedAtMillis: now - 30_000)
        let stop = record(seq: 2, .stopDictation, issuedAtMillis: now - 200)
        let orphanStart = record(seq: 3, .startDictation, issuedAtMillis: now - 400)
        let newestStart = record(seq: 4, .startDictation, issuedAtMillis: now - 100)
        let (preserved, discarded) = SessionStartFlush.partition(
            [oldStart, stop, orphanStart, newestStart], nowMillis: now)
        XCTAssertEqual(preserved, [newestStart], "newest young start only")
        XCTAssertEqual(discarded, [oldStart, stop, orphanStart], "input order kept")
    }

    func testNewestMeansMailboxOrderNotIssuedAt() {
        // Cross-process clock skew can stamp an EARLIER mailbox entry with a
        // LATER issuedAtMillis; drain order is the authoritative "newest".
        let skewedOrphan = record(seq: 1, .startDictation, issuedAtMillis: now + 5_000)
        let armingTap = record(seq: 2, .startDictation, issuedAtMillis: now - 100)
        let (preserved, discarded) = SessionStartFlush.partition(
            [skewedOrphan, armingTap], nowMillis: now)
        XCTAssertEqual(preserved, [armingTap])
        XCTAssertEqual(discarded, [skewedOrphan])
    }

    func testFutureIssuedAtCountsAsYoung() {
        // Wall-clock skew between the two processes must never discard the
        // arming tap's own start.
        let skewed = record(seq: 1, .startDictation, issuedAtMillis: now + 5_000)
        let (preserved, discarded) = SessionStartFlush.partition([skewed], nowMillis: now)
        XCTAssertEqual(preserved, [skewed])
        XCTAssertEqual(discarded, [])
    }

    func testEmptyInputPartitionsToEmpty() {
        let (preserved, discarded) = SessionStartFlush.partition([], nowMillis: now)
        XCTAssertEqual(preserved, [])
        XCTAssertEqual(discarded, [])
    }
}
