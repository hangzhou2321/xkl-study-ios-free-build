import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import StudyCore

struct WordDeck: Decodable {
    let version: String
    let algorithm: Int
    let gradingUnit: String
    let words: [StudyWord]

    static let expectedVersion = "6509be5b320089b638219af4da5b42280e62c9960a6ba7cad67b225b8ec30e42"

    static func load(_ data: Data) throws -> WordDeck {
        let deck = try JSONDecoder().decode(WordDeck.self, from: data)
        guard deck.version == expectedVersion, deck.algorithm == 3,
              deck.gradingUnit == "word", deck.words.count == 25_644,
              deck.words.enumerated().allSatisfy({ $0.offset == $0.element.id && !$0.element.word.isEmpty &&
                  !$0.element.core.isEmpty && $0.element.core.allSatisfy { !$0.meaning.isEmpty } &&
                  $0.element.hasValidConceptMapping }) else {
            throw StudyError.invalidResource("词库版本或单词编号不匹配，已停止载入。")
        }
        return deck
    }
}

struct ContentManifest: Codable {
    let schemaVersion: Int
    let deckVersion: String
    let algorithm: Int
    let stateSchema: Int
    let gradingUnit: String
    let wordCount: Int
    let coreCount: Int
    let deckSHA256: String
    let personalStateSHA256: String
    let personalStateNonzero: Int
    var contentRevision: String? = nil
    var pendingMeaningWords: Int? = nil
}

struct PersonalContent: Codable {
    let format: String
    let deckBytes: Data
    let personalState: Data
    let manifest: ContentManifest

    static let maximumFileBytes = 40 * 1024 * 1024
    static let baselineHash = "f7eff8080cf94d1b00203a5feb45ac387676fe7be20f860c6afb35d8adfbab58"
    static let deckHash = "6977e588d0361767fc7f49e322209773440447e7fbf5bc59b21b3b99278aff60"
    // Content revisions share word IDs and learning identity, but not meaning hashes.
    static let revisedDeckHash = "44893d965f0c6f9d5b61d084ab02c2bb3d8b3b2f63b82d820008b5614e338b3b"
    static let translatedDeckHash = "9fb28391807da46c00bd21bd983c1612213156ef8eae985d7c521411b52b6039"
    static let conceptDeckHash = "8445dd4b892eba743c5ceaa71bd715ff5a36620986c523558924b87634ee6682"
    static let layeredDeckHash = "1c315eaadcbdd2cda83d2b418aab2f2edbb0552a06e19e9efb28f45b02db6c72"
    static let approvedDecks: [String:Int] = [deckHash:43_668,revisedDeckHash:44_460,translatedDeckHash:44_540,conceptDeckHash:43_376,layeredDeckHash:43_376]

    static func load(_ data: Data) throws -> (PersonalContent, WordDeck) {
        guard data.count <= maximumFileBytes else { throw StudyError.invalidResource("内容包超过 40MB，未导入。") }
        let content = try JSONDecoder().decode(PersonalContent.self, from: data)
        let manifest = content.manifest
        guard content.format == "xkl-ios-content-v1", manifest.schemaVersion == 1,
              manifest.deckVersion == WordDeck.expectedVersion, manifest.algorithm == 3,
              manifest.stateSchema == 7, manifest.gradingUnit == "word", manifest.wordCount == 25_644,
              approvedDecks[manifest.deckSHA256] == manifest.coreCount, manifest.personalStateNonzero == 8_550,
              content.personalState.count == 2 * 1024 * 1024,
              manifest.personalStateSHA256 == baselineHash,
              sha256(content.personalState) == manifest.personalStateSHA256,
              sha256(content.deckBytes) == manifest.deckSHA256 else {
            throw StudyError.invalidResource("内容包版本、原学习记录或校验值不匹配，未导入。")
        }
        let deck = try WordDeck.load(content.deckBytes)
        guard deck.words.reduce(0, { $0 + $1.core.count }) == manifest.coreCount else {
            throw StudyError.invalidResource("核心义数量不匹配，未导入。")
        }
        // The C parser additionally validates the original migration image.
        return (content, deck)
    }

    static func bundled() throws -> Data? {
        guard Bundle.main.url(forResource: "deck", withExtension: "json") != nil ||
                Bundle.main.url(forResource: "deck", withExtension: "json", subdirectory: "Resources") != nil else { return nil }
        let manifest = try JSONDecoder().decode(ContentManifest.self, from: ResourceReader.data(named: "resource-manifest", extension: "json"))
        let content = PersonalContent(format: "xkl-ios-content-v1",
                                      deckBytes: try ResourceReader.data(named: "deck", extension: "json"),
                                      personalState: try ResourceReader.data(named: "personal-state", extension: "bin"),
                                      manifest: manifest)
        return try JSONEncoder().encode(content)
    }
}

struct StudyWord: Decodable, Identifiable {
    struct OriginalMeaning: Decodable {
        let pos: String
        let meaning: String
        let cue: String
        var english: String? = nil
        var source: String? = nil
        var usage: [String]? = nil
    }
    struct Meaning: Decodable {
        let pos: String
        let meaning: String
        let cue: String
        var explanation: String? = nil
        var originalMeanings: [OriginalMeaning]? = nil
        var oldCoreIndices: [Int]? = nil
        var usageLabels: [String]? = nil
        var sourceEnglish: String? = nil
        var sourceOriginals: [OriginalMeaning]? = nil
        var newlySourced: Bool? = nil
    }
    let id: Int
    let word: String
    let core: [Meaning]
    let expanded: String
    var sourceLabel: String? = nil
    var meaningPending: Bool? = nil
    var supportingEnglish: String? = nil
    var meaningPresentation: String? = nil
    var originalCoreCount: Int? = nil

    var usesConceptPresentation: Bool { meaningPresentation == "whole-word-concepts-v1" }

    var hasValidConceptMapping: Bool {
        guard let meaningPresentation else { return originalCoreCount == nil }
        guard meaningPresentation == "whole-word-concepts-v1",
              let count = originalCoreCount, (1...1024).contains(count) else { return false }
        var indices: [Int] = []
        for sense in core {
            guard let old = sense.oldCoreIndices,
                  let originals = sense.originalMeanings, originals.count == old.count,
                  originals.allSatisfy({ !$0.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
            if old.isEmpty || sense.newlySourced == true {
                guard sense.newlySourced == true, let sources = sense.sourceOriginals, !sources.isEmpty,
                      sources.allSatisfy({ !($0.english ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          !($0.source ?? "").isEmpty }) else { return false }
            }
            indices.append(contentsOf: old)
        }
        return indices.sorted() == Array(0..<count)
    }

    /// Old order is retained for provenance; current omission indices still
    /// refer to current core groups and are bound to the content revision hash.
    var originalDefinitionText: String {
        guard usesConceptPresentation, hasValidConceptMapping else { return "" }
        // A corrected legacy meaning is kept in the provenance mapping, but
        // the source panel shows the newly checked dictionary definitions.
        if core.contains(where: { $0.newlySourced == true }) {
            return core.flatMap { $0.sourceOriginals ?? $0.originalMeanings ?? [] }.enumerated().map { index, value in
                originalText(index: index, value: value)
            }.joined(separator: "\n\n")
        }
        var ordered: [(Int, OriginalMeaning)] = []
        for sense in core {
            ordered.append(contentsOf: zip(sense.oldCoreIndices ?? [], sense.originalMeanings ?? []))
        }
        return ordered.sorted { $0.0 < $1.0 }.map { index, value in
            originalText(index: index, value: value)
        }.joined(separator: "\n\n")
    }

    private func originalText(index: Int, value: OriginalMeaning) -> String {
        var lines = ["\(index + 1). \(value.pos) \(value.meaning)"]
        if let english = value.english, !english.isEmpty { lines.append(english) }
        if !value.cue.isEmpty { lines.append(value.cue) }
        if let usage = value.usage, !usage.isEmpty { lines.append(usage.joined(separator: "；")) }
        if let source = value.source, !source.isEmpty { lines.append(source) }
        return lines.joined(separator: "\n")
    }
}

struct ContentRevision: Codable, Equatable {
    let firstSequence: UInt32
    let deckSHA256: String
    let changedAt: Date?
    static func comparisonFirstSequence(base: UInt32, revisions: [Self]) -> UInt32 {
        max(base,revisions.last?.firstSequence ?? 1)
    }

    static func reconciled(_ previous: [Self]?, incoming: String, logCount: UInt32,
                           existingArchive: Bool, now: Date = Date()) throws -> [Self] {
        guard PersonalContent.approvedDecks[incoming] != nil, logCount < UInt32.max else {
            throw StudyError.invalidResource("释义版本无法识别，原记录已保留。")
        }
        var rows = previous ?? [Self(firstSequence:1,deckSHA256:existingArchive ? PersonalContent.deckHash:incoming,changedAt:nil)]
        guard !rows.isEmpty, rows.first?.firstSequence == 1,
              rows.allSatisfy({ $0.firstSequence > 0 && $0.firstSequence <= logCount+1 &&
                  PersonalContent.approvedDecks[$0.deckSHA256] != nil }),
              zip(rows,rows.dropFirst()).allSatisfy({ $0.firstSequence <= $1.firstSequence }) else {
            throw StudyError.persistence("释义变更记录校验失败，原学习记录已保留。")
        }
        if rows.last?.deckSHA256 != incoming {
            rows.append(Self(firstSequence:logCount+1,deckSHA256:incoming,changedAt:now))
        }
        return rows
    }
}

enum ResourceReader {
    static func data(named name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            throw StudyError.invalidResource("缺少随应用附带的数据：\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}

enum StudyError: LocalizedError {
    case invalidResource(String)
    case engine(String)
    case persistence(String)
    case sync(String)

    var errorDescription: String? {
        switch self {
        case .invalidResource(let text), .engine(let text), .persistence(let text), .sync(let text):
            return text
        }
    }
}

struct DeviceHello: Codable, Equatable {
    let protocolVersion: Int
    let deviceID: String
    let profileID: String
    let deckVersion: String
    let algorithm: Int
    let schema: Int
    var learningPolicyVersion: Int? = nil
    var contentSHA256: String? = nil

    func compatible(with other: DeviceHello) -> Bool {
        protocolVersion == other.protocolVersion && profileID == other.profileID &&
            deckVersion == other.deckVersion && algorithm == other.algorithm && schema == other.schema &&
            deviceID != other.deviceID && learningPolicyVersion == other.learningPolicyVersion &&
            contentSHA256 == other.contentSHA256
    }
}

// This application envelope adds a version handshake before the StudyCore handoff.
// Every message is framed by BLEFrameCodec; BLE write ACKs are transport ACKs only.
struct DeviceWireMessage: Codable {
    let wireVersion: Int
    let kind: String
    let hello: DeviceHello?
    let envelope: SyncEnvelope?

    static func handshake(_ hello: DeviceHello) -> Self {
        Self(wireVersion: 1, kind: "hello", hello: hello, envelope: nil)
    }

    static func sync(_ envelope: SyncEnvelope) -> Self {
        Self(wireVersion: 1, kind: "sync", hello: nil, envelope: envelope)
    }
}

struct AppDiskRecord: Codable {
    let format: Int
    let syncStateJSON: Data
    var pairedPeripherals: [String: String]
    let provisioningSnapshot: Data?
    let savedAt: Date
    var analysis: StudyAnalysisSettings? = nil
    var legacyBackupSHA256: String? = nil
    var timing: StudyTimingJournal? = nil
    var timingBackupSHA256: String? = nil
    var history: StudyArchiveIndex? = nil
    var historyBackupSHA256: String? = nil
    var annotations: StudyAnnotations? = nil
    var feedbackPrompt: StudyFeedbackPrompt? = nil
    var contentRevisions: [ContentRevision]? = nil

    @MainActor func validatedAnalysis(engine: PocketEngine) throws -> StudyAnalysisSettings {
        if let hash=legacyBackupSHA256 {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw AnalysisError.invalidSettings }
        }
        if format == 1 {
            return StudyAnalysisSettings(streamID: try engine.streamID, nextSequence: try engine.info.log_records+1)
        }
        guard (2...4).contains(format), let settings=analysis else { throw AnalysisError.invalidSettings }
        try settings.validate(streamID: engine.streamID, logCount: engine.info.log_records)
        return settings
    }
    @MainActor func validatedTiming(engine: PocketEngine) throws -> StudyTimingJournal {
        if let hash=timingBackupSHA256 {
            guard hash.count==64,hash.allSatisfy({ $0.isHexDigit }) else { throw AnalysisError.invalidSettings }
        }
        if format==1 || format==2 {
            return StudyTimingJournal(streamID:try engine.streamID,firstSequence:try engine.info.log_records+1)
        }
        guard (format==3 || format==4),let timing else { throw AnalysisError.invalidSettings }
        try timing.validate(streamID:engine.streamID,logCount:engine.info.log_records)
        return timing
    }
    @MainActor func validatedHistory(engine:PocketEngine) throws -> StudyArchiveIndex {
        if let hash=historyBackupSHA256 {
            guard hash.count==64,hash.allSatisfy({$0.isHexDigit}) else { throw AnalysisError.invalidSettings }
        }
        if (1...3).contains(format) {
            guard engine.logBase==0 else { throw AnalysisError.invalidSettings }
            return StudyArchiveIndex(streamID:try engine.streamID)
        }
        guard format==4,let history,let annotations else { throw AnalysisError.invalidSettings }
        try history.validate(streamID:engine.streamID,activeBase:engine.logBase,logCount:engine.info.log_records)
        try annotations.validate(logCount:engine.info.log_records)
        return history
    }
}

struct ReceiverProvisioning: Encodable {
    let format = "xkl-inactive-receiver-v1"
    let learningPolicyVersion = 1
    let analysisMetadataScope = "local to each installation; raw study history transfers, policy receipts do not"
    let exportedAt: Date
    let sourceDeviceID: String
    let receiverDeviceID: String
    let receiverState: SyncState
    let notice = "For first initialization of a blank compatible device only. Never replace an existing device's study data. This file does not flash firmware."
}

struct RecordsExport: Encodable {
    let format = "xkl-ios-records-v4"
    let exportedAt: Date
    let deckVersion: String
    let algorithm: Int
    let checkpointSchema: Int
    let wordCount: Int
    let logRecords: UInt32
    let rawLogEncoding = "base64"
    let rawLogLayout = "active volume: 4096-byte header + 96-byte local records; snapshot-v2 maps global IDs and omits synthetic carry rows; closed volumes are in the ZIP manifest"
    let rawLog: Data
    let logSHA256: String
    let stateSHA256: String
    let durableState: Data
    var analysis: StudyAnalysisSettings? = nil
    var fsrsComparison: FSRSShadowReport? = nil
    var comparisonError: String? = nil
    var preservedLegacyArchive: Data? = nil
    var timing: StudyTimingJournal? = nil
    var dualFSRSComparison: DualFSRSReport? = nil
    var preservedPreTimingArchive: Data? = nil
    var history: StudyArchiveIndex? = nil
    var annotations: StudyAnnotations? = nil
    var preservedPreHistoryArchive: Data? = nil
    var contentRevisions: [ContentRevision]? = nil
    var currentContentSHA256: String? = nil
}

func sha256(_ data: Data) -> String {
#if canImport(CryptoKit)
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
    StudySHA256.hex(data)
#endif
}
