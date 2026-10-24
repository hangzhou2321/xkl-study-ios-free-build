import Foundation

public enum SyncError: Error, Equatable {
    case invalidState, invalidMetadata, wrongProfile, wrongDeck, incompatibleVersion
    case unauthorizedPeer, wrongRecipient, invalidSnapshot, snapshotTooLarge, snapshotValidatorRequired
    case sourceLocked, alreadyInProgress, unexpectedMessage, divergentBranch, conflictCapacity
    case staleTransition, staleTransaction, persistenceNotAcknowledged, messageTooLarge
}

public enum SyncMessageKind: String, Codable { case offer, ready, commit, ack, status, reject }
public enum SyncRemoteStatus: String, Codable { case query, staged, awaitingReady, awaitingAck, committed, unknown, conflict }
public enum SyncOwnership: String, Codable { case active, locked, inactive }
public enum HandoffDirection: String, Codable { case outgoing, incoming }
public enum HandoffPhase: String, Codable { case offered, staged, committed }

public struct SyncEnvelope: Codable, Equatable {
    public var protocolVersion: Int = 1
    public var kind: SyncMessageKind
    public var profileID: String
    public var deckVersion: String
    public var algorithm: Int
    public var schema: Int
    public var transactionID: String
    public var transactionSequence: UInt64
    public var sourceDeviceID: String
    public var targetDeviceID: String
    public var baselineHash: String
    public var snapshotHash: String
    public var snapshot: Data?
    public var status: SyncRemoteStatus?
    public var reason: String?

    public init(kind: SyncMessageKind, profileID: String, deckVersion: String, algorithm: Int, schema: Int,
                transactionID: String, sourceDeviceID: String, targetDeviceID: String,
                baselineHash: String, snapshotHash: String, snapshot: Data? = nil,
                status: SyncRemoteStatus? = nil, reason: String? = nil, transactionSequence: UInt64 = 1) {
        self.kind=kind; self.profileID=profileID; self.deckVersion=deckVersion; self.algorithm=algorithm; self.schema=schema
        self.transactionID=transactionID; self.transactionSequence=transactionSequence
        self.sourceDeviceID=sourceDeviceID; self.targetDeviceID=targetDeviceID
        self.baselineHash=baselineHash; self.snapshotHash=snapshotHash; self.snapshot=snapshot; self.status=status; self.reason=reason
    }

    public func encoded() throws -> Data {
        let data = try SyncJSON.encode(self)
        guard data.count <= BLEFrameCodec.maximumWireSize else { throw SyncError.messageTooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> SyncEnvelope {
        guard data.count <= BLEFrameCodec.maximumWireSize else { throw SyncError.messageTooLarge }
        return try JSONDecoder().decode(SyncEnvelope.self, from: data)
    }
}

public struct PendingHandoff: Codable, Equatable {
    public var direction: HandoffDirection
    public var phase: HandoffPhase
    public var transactionID: String
    public var transactionSequence: UInt64
    public var peerID: String
    public var baselineHash: String
    public var snapshotHash: String
    /// Only the receiver stores a staged snapshot here; sender keeps its own snapshot.
    public var snapshot: Data?
}

public struct SyncReceipt: Codable, Equatable {
    public var transactionID: String
    public var transactionSequence: UInt64
    public var peerID: String
    public var baselineHash: String
    public var snapshotHash: String
}

/// A divergent incoming branch is retained alongside the local snapshot, never applied.
public struct SyncConflict: Codable, Equatable {
    public var transactionID: String
    public var peerID: String
    public var baselineHash: String
    public var localHeadHash: String
    public var remoteHeadHash: String
    public var remoteSnapshot: Data
    public var reason: String
}

public struct SyncState: Codable, Equatable {
    public static let formatVersion = 1
    public static let maximumSnapshotSize = 2_300_000
    public var version: Int = 1
    public var generation: UInt64 = 0
    public var outboundSequence: UInt64 = 0
    public var highestIncomingSequence: [String: UInt64] = [:]
    public var profileID: String
    public var deviceID: String
    public var deckVersion: String
    public var algorithm: Int
    public var schema: Int
    public var ownership: SyncOwnership
    public var snapshot: Data
    public var headHash: String
    public var baselineHash: String
    public var trustedPeerIDs: [String] = []
    public var pending: PendingHandoff?
    public var receipts: [SyncReceipt] = []
    public var conflicts: [SyncConflict] = []
    public var lastIssue: String?
    public var canStudy: Bool { ownership == .active && pending == nil }

    /// Provision only one device as active. All other devices need exactly the
    /// same initial snapshot/baseline and active=false, before their first handoff.
    public static func initial(profileID: String, deviceID: String, deckVersion: String,
                               algorithm: Int = 3, schema: Int = 7, snapshot: Data,
                               active: Bool, trustedPeerIDs: [String] = []) throws -> SyncState {
        guard !snapshot.isEmpty, snapshot.count <= maximumSnapshotSize else { throw SyncError.invalidSnapshot }
        let hash = StudySHA256.hex(snapshot)
        let result = SyncState(profileID: profileID, deviceID: deviceID, deckVersion: deckVersion,
                               algorithm: algorithm, schema: schema, ownership: active ? .active : .inactive,
                               snapshot: snapshot, headHash: hash, baselineHash: hash, trustedPeerIDs: trustedPeerIDs)
        try result.validate()
        return result
    }

    public func encoded() throws -> Data { try SyncJSON.encode(self) }

    fileprivate func validate() throws {
        guard version == Self.formatVersion, algorithm == 3, schema == 7 else { throw SyncError.incompatibleVersion }
        guard SyncJSON.identifier(profileID), SyncJSON.identifier(deviceID), SyncJSON.hash(deckVersion),
              SyncJSON.hash(headHash), SyncJSON.hash(baselineHash), !snapshot.isEmpty,
              snapshot.count <= Self.maximumSnapshotSize, StudySHA256.hex(snapshot) == headHash,
              trustedPeerIDs.count <= 16, Set(trustedPeerIDs).count == trustedPeerIDs.count,
              trustedPeerIDs.allSatisfy({ SyncJSON.identifier($0) && $0 != deviceID }),
              receipts.count <= 64, conflicts.count <= 4,
              highestIncomingSequence.count <= 16,
              highestIncomingSequence.allSatisfy({ trustedPeerIDs.contains($0.key) && $0.value > 0 }) else { throw SyncError.invalidState }
        if let p = pending {
            guard SyncJSON.identifier(p.transactionID), p.transactionSequence > 0, trustedPeerIDs.contains(p.peerID),
                  SyncJSON.hash(p.baselineHash), SyncJSON.hash(p.snapshotHash) else { throw SyncError.invalidState }
            switch (p.direction, p.phase) {
            case (.outgoing, .offered):
                guard ownership == .locked, p.snapshot == nil, p.snapshotHash == headHash, p.baselineHash == baselineHash,
                      p.transactionSequence == outboundSequence else { throw SyncError.invalidState }
            case (.outgoing, .committed):
                guard ownership == .inactive, p.snapshot == nil, p.snapshotHash == headHash, baselineHash == headHash,
                      p.transactionSequence == outboundSequence else { throw SyncError.invalidState }
            case (.incoming, .staged):
                guard ownership == .inactive, let staged=p.snapshot, !staged.isEmpty,
                      staged.count <= Self.maximumSnapshotSize, StudySHA256.hex(staged) == p.snapshotHash,
                      p.baselineHash == baselineHash, headHash == baselineHash,
                      highestIncomingSequence[p.peerID] == p.transactionSequence else { throw SyncError.invalidState }
            default: throw SyncError.invalidState
            }
        } else if ownership == .locked { throw SyncError.invalidState }
        for receipt in receipts {
            guard SyncJSON.identifier(receipt.transactionID), SyncJSON.identifier(receipt.peerID), receipt.transactionSequence > 0,
                  receipt.transactionSequence <= (highestIncomingSequence[receipt.peerID] ?? 0),
                  SyncJSON.hash(receipt.baselineHash), SyncJSON.hash(receipt.snapshotHash) else { throw SyncError.invalidState }
        }
        for conflict in conflicts {
            guard SyncJSON.identifier(conflict.transactionID), SyncJSON.identifier(conflict.peerID),
                  SyncJSON.hash(conflict.baselineHash), SyncJSON.hash(conflict.localHeadHash),
                  SyncJSON.hash(conflict.remoteHeadHash), !conflict.remoteSnapshot.isEmpty,
                  conflict.remoteSnapshot.count <= Self.maximumSnapshotSize,
                  StudySHA256.hex(conflict.remoteSnapshot) == conflict.remoteHeadHash,
                  conflict.reason.utf8.count <= 256 else { throw SyncError.invalidState }
        }
    }
}

public enum SyncInput {
    case authorizePeer(String)
    case localSnapshot(Data)
    case beginHandoff(peerID: String)
    case receive(SyncEnvelope)
    case retry
    case checkStatus
}

/// No transport or activation effect is available until this exact state has
/// been acknowledged as durably written by the caller.
public struct SyncTransition {
    public let encodedState: Data
    fileprivate let previousGeneration: UInt64
    fileprivate let previousDigest: String
    fileprivate let next: SyncState
    fileprivate let effects: SyncEffects
}

public struct SyncEffects {
    public let outgoing: [SyncEnvelope]
    public let activationSnapshot: Data?
}

/// Serialized by the app. This layer performs no disk I/O and no BLE I/O.
/// The caller MUST atomically write transition.encodedState, synchronize the
/// file as required, then acknowledgePersistence with those exact saved bytes.
/// Never send packets on a successful BLE write alone, or reactivate a sender
/// because a timeout elapsed. Lost ACKs are resolved by retry/STATUS.
public struct SyncCoordinator {
    public private(set) var state: SyncState
    private let snapshotValidator: ((Data) throws -> Void)?

    public init(state: SyncState, snapshotValidator: ((Data) throws -> Void)? = nil) throws {
        try state.validate()
        if let validate = snapshotValidator {
            try validate(state.snapshot)
            if let snapshot = state.pending?.snapshot { try validate(snapshot) }
            for conflict in state.conflicts { try validate(conflict.remoteSnapshot) }
        }
        self.state=state; self.snapshotValidator=snapshotValidator
    }

    public func propose(_ input: SyncInput) throws -> SyncTransition {
        var next = state
        var outgoing: [SyncEnvelope] = []
        var activation: Data?
        switch input {
        case .authorizePeer(let peer):
            guard SyncJSON.identifier(peer), peer != state.deviceID else { throw SyncError.invalidMetadata }
            if !next.trustedPeerIDs.contains(peer) {
                guard next.trustedPeerIDs.count < 16 else { throw SyncError.invalidState }
                next.trustedPeerIDs.append(peer)
                next.trustedPeerIDs.sort()
            }
        case .localSnapshot(let snapshot):
            guard state.canStudy else { throw SyncError.sourceLocked }
            try validateSnapshot(snapshot)
            next.snapshot=snapshot; next.headHash=StudySHA256.hex(snapshot)
        case .beginHandoff(let peer):
            guard state.canStudy else { throw SyncError.sourceLocked }
            guard state.trustedPeerIDs.contains(peer) else { throw SyncError.unauthorizedPeer }
            guard state.outboundSequence < UInt64.max else { throw SyncError.invalidState }
            next.outboundSequence += 1
            next.ownership = .locked
            next.lastIssue = nil
            next.pending = PendingHandoff(direction: .outgoing, phase: .offered,
                transactionID: UUID().uuidString.lowercased(), transactionSequence:next.outboundSequence, peerID: peer,
                baselineHash: state.baselineHash, snapshotHash: state.headHash, snapshot: nil)
            outgoing = [Self.envelope(next, next.pending!, .offer, snapshot: next.snapshot)]
        case .retry:
            if let p = state.pending {
                switch (p.direction, p.phase) {
                case (.outgoing, .offered): outgoing = [Self.envelope(state,p,.offer,snapshot:state.snapshot)]
                case (.outgoing, .committed): outgoing = [Self.envelope(state,p,.commit)]
                case (.incoming, .staged): outgoing = [Self.envelope(state,p,.status,status:.query)]
                default: throw SyncError.invalidState
                }
            }
        case .checkStatus:
            if let p=state.pending { outgoing = [Self.envelope(state,p,.status,status:.query)] }
        case .receive(let message):
            try validateMessage(message)
            switch message.kind {
            case .offer:
                guard let snapshot=message.snapshot else { throw SyncError.invalidSnapshot }
                try validateSnapshot(snapshot)
                guard StudySHA256.hex(snapshot) == message.snapshotHash else { throw SyncError.invalidSnapshot }
                if let receipt=matchingReceipt(message) {
                    outgoing = [Self.reply(state,message,.ack,receipt:receipt)]
                } else if let p=state.pending {
                    guard Self.matches(p,message) else { throw SyncError.alreadyInProgress }
                    guard p.direction == .incoming, p.phase == .staged, p.snapshot == snapshot else { throw SyncError.unexpectedMessage }
                    outgoing = [Self.envelope(state,p,.ready)]
                } else if message.transactionSequence <= (state.highestIncomingSequence[message.sourceDeviceID] ?? 0) {
                    throw SyncError.staleTransaction
                } else if state.headHash != state.baselineHash || message.baselineHash != state.baselineHash {
                    if !next.conflicts.contains(where: { $0.transactionID == message.transactionID && $0.peerID == message.sourceDeviceID && $0.remoteHeadHash == message.snapshotHash }) {
                        guard next.conflicts.count < 4 else { throw SyncError.conflictCapacity }
                        next.conflicts.append(SyncConflict(transactionID:message.transactionID,peerID:message.sourceDeviceID,
                            baselineHash:message.baselineHash,localHeadHash:state.headHash,remoteHeadHash:message.snapshotHash,
                            remoteSnapshot:snapshot,reason:"divergent-branch"))
                    }
                    next.lastIssue = "divergent-branch"
                    outgoing = [Self.reply(state,message,.reject,reason:"divergent-branch")]
                } else if state.ownership != .inactive {
                    next.lastIssue = "receiver-active"
                    outgoing = [Self.reply(state,message,.reject,reason:"receiver-active")]
                } else {
                    next.highestIncomingSequence[message.sourceDeviceID] = message.transactionSequence
                    next.pending = PendingHandoff(direction:.incoming,phase:.staged,transactionID:message.transactionID,
                        transactionSequence:message.transactionSequence,
                        peerID:message.sourceDeviceID,baselineHash:message.baselineHash,snapshotHash:message.snapshotHash,snapshot:snapshot)
                    next.lastIssue=nil
                    outgoing = [Self.envelope(next,next.pending!,.ready)]
                }
            case .ready:
                guard let p=state.pending, p.direction == .outgoing, Self.matches(p,message) else { throw SyncError.unexpectedMessage }
                if p.phase == .offered {
                    next.pending?.phase = .committed
                    next.ownership = .inactive
                    next.baselineHash = next.headHash
                } else if p.phase != .committed { throw SyncError.unexpectedMessage }
                outgoing = [Self.envelope(next,next.pending!,.commit)]
            case .commit:
                if let receipt=matchingReceipt(message) {
                    // An old COMMIT must never reactivate a device that handed off again.
                    outgoing = [Self.reply(state,message,.ack,receipt:receipt)]
                } else {
                    guard let p=state.pending, p.direction == .incoming, p.phase == .staged,
                          Self.matches(p,message), let snapshot=p.snapshot, state.ownership == .inactive else { throw SyncError.unexpectedMessage }
                    next.snapshot=snapshot; next.headHash=p.snapshotHash; next.baselineHash=p.snapshotHash
                    next.ownership = .active; next.pending=nil; next.lastIssue=nil
                    let receipt = SyncReceipt(transactionID:p.transactionID,transactionSequence:p.transactionSequence,
                        peerID:p.peerID,baselineHash:p.baselineHash,snapshotHash:p.snapshotHash)
                    next.receipts.append(receipt)
                    if next.receipts.count > 64 { next.receipts.removeFirst() }
                    activation=snapshot
                    outgoing = [Self.reply(next,message,.ack,receipt:receipt)]
                }
            case .ack:
                if let p=state.pending {
                    guard p.direction == .outgoing, p.phase == .committed, Self.matches(p,message) else { throw SyncError.unexpectedMessage }
                    next.pending=nil; next.lastIssue=nil
                } else {
                    // Duplicate ACK after completion does not change ownership or state.
                    guard state.ownership == .inactive, state.headHash == message.snapshotHash else { throw SyncError.unexpectedMessage }
                }
            case .status:
                guard let status=message.status else { throw SyncError.invalidMetadata }
                if status == .query {
                    if let receipt=matchingReceipt(message) {
                        outgoing = [Self.reply(state,message,.status,status:.committed,receipt:receipt)]
                    } else if let p=state.pending, Self.matches(p,message) {
                        let remote: SyncRemoteStatus = p.direction == .incoming ? .staged : (p.phase == .committed ? .awaitingAck : .awaitingReady)
                        outgoing = [Self.envelope(state,p,.status,status:remote)]
                    } else { outgoing = [Self.reply(state,message,.status,status:.unknown)] }
                } else {
                    guard let p=state.pending, Self.matches(p,message) else { throw SyncError.unexpectedMessage }
                    if p.direction == .outgoing {
                        switch status {
                        case .staged:
                            if p.phase == .offered {
                                next.pending?.phase = .committed; next.ownership = .inactive; next.baselineHash=next.headHash
                            }
                            outgoing = [Self.envelope(next,next.pending!,.commit)]
                        case .committed:
                            guard p.phase == .committed else { throw SyncError.unexpectedMessage }
                            next.pending=nil; next.lastIssue=nil
                        case .unknown:
                            // Source remains locked/inactive; re-stage before retrying COMMIT.
                            outgoing = [Self.envelope(state,p,.offer,snapshot:state.snapshot)]
                        case .conflict: next.lastIssue="peer-conflict"
                        default: throw SyncError.unexpectedMessage
                        }
                    } else {
                        switch status {
                        case .awaitingReady, .awaitingAck: outgoing = [Self.envelope(state,p,.ready)]
                        case .unknown, .conflict: next.lastIssue="handoff-unresolved"
                        default: throw SyncError.unexpectedMessage
                        }
                    }
                }
            case .reject:
                guard let p=state.pending, p.direction == .outgoing, Self.matches(p,message) else { throw SyncError.unexpectedMessage }
                // Do not infer permission to resume from a rejection or a timeout.
                next.lastIssue=message.reason ?? "peer-rejected"
            }
        }
        guard state.generation < UInt64.max else { throw SyncError.invalidState }
        next.generation=state.generation+1
        try next.validate()
        for message in outgoing { _ = try message.encoded() }
        return SyncTransition(encodedState:try next.encoded(),previousGeneration:state.generation,
            previousDigest:StudySHA256.hex(try state.encoded()),next:next,
            effects:SyncEffects(outgoing:outgoing,activationSnapshot:activation))
    }

    /// The persistence acknowledgment is a caller contract, not proof that the
    /// operating system flushed bytes. A failed write must never call this method.
    public mutating func acknowledgePersistence(_ transition: SyncTransition, persistedState: Data) throws -> SyncEffects {
        guard state.generation == transition.previousGeneration,
              StudySHA256.hex(try state.encoded()) == transition.previousDigest else { throw SyncError.staleTransition }
        guard persistedState == transition.encodedState else { throw SyncError.persistenceNotAcknowledged }
        state=transition.next
        return transition.effects
    }

    private func validateSnapshot(_ data: Data) throws {
        guard !data.isEmpty else { throw SyncError.invalidSnapshot }
        guard data.count <= SyncState.maximumSnapshotSize else { throw SyncError.snapshotTooLarge }
        guard let validate=snapshotValidator else { throw SyncError.snapshotValidatorRequired }
        try validate(data)
    }

    private func validateMessage(_ m: SyncEnvelope) throws {
        guard m.protocolVersion == 1, m.algorithm == state.algorithm, m.schema == state.schema else { throw SyncError.incompatibleVersion }
        guard m.profileID == state.profileID else { throw SyncError.wrongProfile }
        guard m.deckVersion == state.deckVersion else { throw SyncError.wrongDeck }
        guard m.targetDeviceID == state.deviceID else { throw SyncError.wrongRecipient }
        guard m.sourceDeviceID != state.deviceID, state.trustedPeerIDs.contains(m.sourceDeviceID) else { throw SyncError.unauthorizedPeer }
        guard SyncJSON.identifier(m.transactionID), m.transactionSequence > 0, SyncJSON.hash(m.baselineHash), SyncJSON.hash(m.snapshotHash),
              (m.reason?.utf8.count ?? 0) <= 256 else { throw SyncError.invalidMetadata }
        guard (m.kind == .offer) == (m.snapshot != nil), (m.kind == .status) == (m.status != nil) else { throw SyncError.invalidMetadata }
        _ = try m.encoded()
    }

    private func matchingReceipt(_ m: SyncEnvelope) -> SyncReceipt? {
        state.receipts.first { $0.transactionID == m.transactionID && $0.transactionSequence == m.transactionSequence &&
            $0.peerID == m.sourceDeviceID && $0.baselineHash == m.baselineHash && $0.snapshotHash == m.snapshotHash }
    }
    private static func matches(_ p: PendingHandoff, _ m: SyncEnvelope) -> Bool {
        p.transactionID == m.transactionID && p.transactionSequence == m.transactionSequence &&
            p.peerID == m.sourceDeviceID && p.baselineHash == m.baselineHash && p.snapshotHash == m.snapshotHash
    }
    private static func envelope(_ s: SyncState, _ p: PendingHandoff, _ kind: SyncMessageKind,
                                 snapshot: Data? = nil, status: SyncRemoteStatus? = nil) -> SyncEnvelope {
        SyncEnvelope(kind:kind,profileID:s.profileID,deckVersion:s.deckVersion,algorithm:s.algorithm,schema:s.schema,
            transactionID:p.transactionID,sourceDeviceID:s.deviceID,targetDeviceID:p.peerID,
            baselineHash:p.baselineHash,snapshotHash:p.snapshotHash,snapshot:snapshot,status:status,transactionSequence:p.transactionSequence)
    }
    private static func reply(_ s: SyncState, _ m: SyncEnvelope, _ kind: SyncMessageKind,
                              status: SyncRemoteStatus? = nil, reason: String? = nil, receipt: SyncReceipt? = nil) -> SyncEnvelope {
        SyncEnvelope(kind:kind,profileID:s.profileID,deckVersion:s.deckVersion,algorithm:s.algorithm,schema:s.schema,
            transactionID:receipt?.transactionID ?? m.transactionID,sourceDeviceID:s.deviceID,targetDeviceID:m.sourceDeviceID,
            baselineHash:receipt?.baselineHash ?? m.baselineHash,snapshotHash:receipt?.snapshotHash ?? m.snapshotHash,status:status,reason:reason,
            transactionSequence:receipt?.transactionSequence ?? m.transactionSequence)
    }
}

private enum SyncJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
    static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
