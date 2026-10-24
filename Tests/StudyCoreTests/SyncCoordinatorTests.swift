import XCTest
@testable import StudyCore

final class SyncCoordinatorTests: XCTestCase {
    private let deck=String(repeating:"a",count:64)
    private let original=Data("original personal study state".utf8)

    private func make(_ id: String, active: Bool, snapshot: Data? = nil) throws -> SyncCoordinator {
        try SyncCoordinator(state:.initial(profileID:"local-profile",deviceID:id,deckVersion:deck,
            snapshot:snapshot ?? original,active:active,trustedPeerIDs:[id == "phone" ? "pocket" : "phone"]),
            snapshotValidator:{ data in if data.isEmpty { throw SyncError.invalidSnapshot } })
    }
    @discardableResult private func persist(_ coordinator: inout SyncCoordinator, _ input: SyncInput) throws -> SyncEffects {
        let transition=try coordinator.propose(input)
        // The app substitutes a real atomic durable file write at this boundary.
        let saved=transition.encodedState
        return try coordinator.acknowledgePersistence(transition,persistedState:saved)
    }
    private func restart(_ coordinator: SyncCoordinator) throws -> SyncCoordinator {
        let decoded=try JSONDecoder().decode(SyncState.self,from:coordinator.state.encoded())
        return try SyncCoordinator(state:decoded,snapshotValidator:{ _ in })
    }
    private func transfer(_ sender: inout SyncCoordinator, _ receiver: inout SyncCoordinator) throws -> (offer:SyncEnvelope,commit:SyncEnvelope,ack:SyncEnvelope) {
        let offer=try persist(&sender,.beginHandoff(peerID:receiver.state.deviceID)).outgoing[0]
        let ready=try persist(&receiver,.receive(offer)).outgoing[0]
        let commit=try persist(&sender,.receive(ready)).outgoing[0]
        let ack=try persist(&receiver,.receive(commit)).outgoing[0]
        try persist(&sender,.receive(ack))
        return (offer,commit,ack)
    }

    func testSourceLockRequiresPersistenceAndCannotStudyAfterOffer() throws {
        var a=try make("phone",active:true)
        let transition=try a.propose(.beginHandoff(peerID:"pocket"))
        XCTAssertTrue(a.state.canStudy)
        XCTAssertThrowsError(try a.acknowledgePersistence(transition,persistedState:Data())) { XCTAssertEqual($0 as? SyncError,.persistenceNotAcknowledged) }
        let effects=try a.acknowledgePersistence(transition,persistedState:transition.encodedState)
        XCTAssertEqual(effects.outgoing.first?.kind,.offer)
        XCTAssertEqual(a.state.ownership,.locked)
        XCTAssertFalse(a.state.canStudy)
        XCTAssertThrowsError(try a.propose(.localSnapshot(Data("illegal extra answer".utf8))))
        XCTAssertThrowsError(try a.propose(.beginHandoff(peerID:"pocket")))
        a=try restart(a)
        XCTAssertFalse(a.state.canStudy)
        XCTAssertEqual(try persist(&a,.retry).outgoing.first?.transactionID,effects.outgoing.first?.transactionID)
    }

    func testStaleTransitionCannotPublishEffects() throws {
        var a=try make("phone",active:true)
        let first=try a.propose(.beginHandoff(peerID:"pocket"))
        try persist(&a,.localSnapshot(Data("new state".utf8)))
        XCTAssertThrowsError(try a.acknowledgePersistence(first,persistedState:first.encodedState)) { XCTAssertEqual($0 as? SyncError,.staleTransition) }
        XCTAssertTrue(a.state.canStudy)
    }

    func testLostReadyCommitAndAckRecoverAcrossRestart() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        let learned=Data("25 new words plus unlimited reviews".utf8)
        try persist(&a,.localSnapshot(learned))
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        _=try persist(&b,.receive(offer)) // READY lost
        XCTAssertFalse(a.state.canStudy); XCTAssertFalse(b.state.canStudy)
        a=try restart(a); b=try restart(b)
        let retryOffer=try persist(&a,.retry).outgoing[0]
        let ready=try persist(&b,.receive(retryOffer)).outgoing[0]
        _=try persist(&a,.receive(ready)) // COMMIT lost
        XCTAssertEqual(a.state.ownership,.inactive)
        a=try restart(a)
        let commit=try persist(&a,.retry).outgoing[0]
        let activation=try persist(&b,.receive(commit)) // ACK lost
        XCTAssertEqual(activation.activationSnapshot,learned)
        XCTAssertTrue(b.state.canStudy); XCTAssertFalse(a.state.canStudy)
        b=try restart(b)
        let repeated=try persist(&b,.receive(commit))
        XCTAssertNil(repeated.activationSnapshot)
        XCTAssertEqual(b.state.receipts.count,1)
        try persist(&a,.receive(repeated.outgoing[0]))
        XCTAssertNil(a.state.pending)
        XCTAssertEqual(a.state.snapshot,b.state.snapshot)
        XCTAssertFalse(a.state.canStudy); XCTAssertTrue(b.state.canStudy)
    }

    func testReceiverCanReconcileStagedTransferUsingStatus() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        _=try persist(&b,.receive(offer))
        let query=try persist(&b,.retry).outgoing[0]
        XCTAssertEqual(query.kind,.status); XCTAssertEqual(query.status,.query)
        let status=try persist(&a,.receive(query)).outgoing[0]
        XCTAssertEqual(status.status,.awaitingReady)
        let ready=try persist(&b,.receive(status)).outgoing[0]
        let commit=try persist(&a,.receive(ready)).outgoing[0]
        let ack=try persist(&b,.receive(commit)).outgoing[0]
        try persist(&a,.receive(ack))
        XCTAssertTrue(b.state.canStudy); XCTAssertFalse(a.state.canStudy)
    }

    func testReverseHandoffAndOldCommitNeverReactivatesPreviousReceiver() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        let first=try transfer(&a,&b)
        try persist(&b,.localSnapshot(Data("learned on pocket".utf8)))
        _=try transfer(&b,&a)
        XCTAssertTrue(a.state.canStudy); XCTAssertFalse(b.state.canStudy)
        let replay=try persist(&b,.receive(first.commit))
        XCTAssertEqual(replay.outgoing.first?.kind,.ack)
        XCTAssertNil(replay.activationSnapshot)
        XCTAssertFalse(b.state.canStudy)
    }

    func testEvictedReceiptCannotReplayOfferAndCommitToStealOwnership() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        let first=try transfer(&a,&b)
        _=try transfer(&b,&a)
        for _ in 0..<64 {
            _=try transfer(&a,&b)
            _=try transfer(&b,&a)
        }
        XCTAssertEqual(b.state.receipts.count,64)
        XCTAssertFalse(b.state.receipts.contains { $0.transactionID == first.offer.transactionID })
        b=try restart(b)
        XCTAssertThrowsError(try b.propose(.receive(first.offer))) { XCTAssertEqual($0 as? SyncError,.staleTransaction) }
        XCTAssertThrowsError(try b.propose(.receive(first.commit)))
        XCTAssertTrue(a.state.canStudy); XCTAssertFalse(b.state.canStudy)
    }

    func testStatusResolvesLostAckButCannotAuthorizeUncommittedSender() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        var forged=offer
        forged.kind = .status; forged.snapshot=nil; forged.status = .committed
        forged.sourceDeviceID="pocket"; forged.targetDeviceID="phone"
        XCTAssertThrowsError(try a.propose(.receive(forged)))
        XCTAssertEqual(a.state.ownership,.locked)
        let ready=try persist(&b,.receive(offer)).outgoing[0]
        let commit=try persist(&a,.receive(ready)).outgoing[0]
        _=try persist(&b,.receive(commit))
        let query=try persist(&a,.checkStatus).outgoing[0]
        let status=try persist(&b,.receive(query)).outgoing[0]
        XCTAssertEqual(status.status,.committed)
        try persist(&a,.receive(status))
        XCTAssertNil(a.state.pending)
        XCTAssertFalse(a.state.canStudy); XCTAssertTrue(b.state.canStudy)
    }

    func testDivergentBranchesPreserveBothSnapshots() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:true)
        let branchA=Data("phone branch".utf8), branchB=Data("pocket branch".utf8)
        try persist(&a,.localSnapshot(branchA)); try persist(&b,.localSnapshot(branchB))
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        let reject=try persist(&b,.receive(offer)).outgoing[0]
        XCTAssertEqual(reject.kind,.reject)
        XCTAssertEqual(b.state.snapshot,branchB)
        XCTAssertEqual(b.state.conflicts.first?.remoteSnapshot,branchA)
        XCTAssertEqual(b.state.conflicts.count,1)
        _=try persist(&b,.receive(offer))
        XCTAssertEqual(b.state.conflicts.count,1)
        try persist(&a,.receive(reject))
        XCTAssertEqual(a.state.snapshot,branchA)
        XCTAssertFalse(a.state.canStudy)
        b=try restart(b)
        XCTAssertEqual(b.state.conflicts.first?.remoteSnapshot,branchA)
    }

    func testCannotActivateWithoutStagedOfferOrFromUntrustedPeer() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:false)
        var forged=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        forged.kind = .commit; forged.snapshot=nil
        XCTAssertThrowsError(try b.propose(.receive(forged))) { XCTAssertEqual($0 as? SyncError,.unexpectedMessage) }
        XCTAssertFalse(b.state.canStudy)
        forged.sourceDeviceID="unknown-device"
        XCTAssertThrowsError(try b.propose(.receive(forged))) { XCTAssertEqual($0 as? SyncError,.unauthorizedPeer) }
        forged.sourceDeviceID="phone"; forged.profileID="other-profile"
        XCTAssertThrowsError(try b.propose(.receive(forged))) { XCTAssertEqual($0 as? SyncError,.wrongProfile) }
        XCTAssertNil(b.state.pending)
        _=try persist(&b,.retry)
        XCTAssertFalse(b.state.canStudy)
    }

    func testOfferRejectsWrongDeckVersionHashAndCValidatorFailure() throws {
        var a=try make("phone",active:true)
        let b=try make("pocket",active:false)
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        var broken=offer; broken.deckVersion=String(repeating:"b",count:64)
        XCTAssertThrowsError(try b.propose(.receive(broken))) { XCTAssertEqual($0 as? SyncError,.wrongDeck) }
        broken=offer; broken.algorithm=4
        XCTAssertThrowsError(try b.propose(.receive(broken))) { XCTAssertEqual($0 as? SyncError,.incompatibleVersion) }
        broken=offer; broken.schema=8
        XCTAssertThrowsError(try b.propose(.receive(broken))) { XCTAssertEqual($0 as? SyncError,.incompatibleVersion) }
        broken=offer; broken.snapshot=Data("corrupt".utf8)
        XCTAssertThrowsError(try b.propose(.receive(broken))) { XCTAssertEqual($0 as? SyncError,.invalidSnapshot) }
        let missingValidator=try SyncCoordinator(state:b.state)
        XCTAssertThrowsError(try missingValidator.propose(.receive(offer))) { XCTAssertEqual($0 as? SyncError,.snapshotValidatorRequired) }
        let strict=try SyncCoordinator(state:b.state,snapshotValidator:{ data in
            guard data == self.original else { throw SyncError.invalidSnapshot }
        })
        broken=offer; broken.snapshot=Data("not a C archive".utf8); broken.snapshotHash=StudySHA256.hex(broken.snapshot!)
        XCTAssertThrowsError(try strict.propose(.receive(broken)))
        XCTAssertEqual(b.state.snapshot,original)
    }

    func testActiveReceiverCannotAcceptEvenIdenticalSnapshot() throws {
        var a=try make("phone",active:true), b=try make("pocket",active:true)
        let offer=try persist(&a,.beginHandoff(peerID:"pocket")).outgoing[0]
        let rejected=try persist(&b,.receive(offer))
        XCTAssertEqual(rejected.outgoing.first?.reason,"receiver-active")
        XCTAssertTrue(b.state.canStudy)
        XCTAssertNil(b.state.pending)
    }

    func testStateTamperAndOversizeRejected() throws {
        let a=try make("phone",active:true)
        var state=a.state
        state.snapshot.append(0)
        XCTAssertThrowsError(try SyncCoordinator(state:state))
        state=a.state; state.ownership = .locked
        XCTAssertThrowsError(try SyncCoordinator(state:state))
        XCTAssertThrowsError(try a.propose(.localSnapshot(Data(repeating:0,count:SyncState.maximumSnapshotSize+1))))
    }

    func testMaxSnapshotJSONFitsFourMiBWithoutNestedBase64() throws {
        let bytes=Data(repeating:0x61,count:SyncState.maximumSnapshotSize)
        let hash=StudySHA256.hex(bytes)
        let envelope=SyncEnvelope(kind:.offer,profileID:"profile",deckVersion:deck,algorithm:3,schema:7,
            transactionID:"test-transaction",sourceDeviceID:"phone",targetDeviceID:"pocket",
            baselineHash:hash,snapshotHash:hash,snapshot:bytes)
        struct Wire: Codable { var kind="sync"; var envelope:SyncEnvelope }
        let encoded=try JSONEncoder().encode(Wire(envelope:envelope))
        XCTAssertLessThan(encoded.count,BLEFrameCodec.maximumWireSize)
        XCTAssertEqual(try SyncEnvelope.decode(envelope.encoded()),envelope)
    }
}
