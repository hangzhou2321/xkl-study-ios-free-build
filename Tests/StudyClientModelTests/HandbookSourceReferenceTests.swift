import Foundation
import XCTest
@testable import StudyClientModel

final class HandbookSourceReferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    // Canonical JSON from the pre-multiple-source schema, with independent SHA-256 goldens.
    private let legacyJSON = #"{"cards":[{"answerSummary":"Synthetic answer","blocks":[],"chapterID":"chapter","examples":[],"id":"synthetic-card","prompt":"Recall a synthetic fact","sourceGroupIDs":["synthetic-group"],"sourceNotes":[],"sourcePages":[1],"title":"Synthetic card","topicNumber":1}],"chapters":[{"id":"chapter","title":"Synthetic chapter"}],"format":"xkl-handbook-cards-v1","id":"synthetic-book","revision":"1.0","source":{"fileName":"original.pdf","includedPages":[1,2],"pdfPageCount":2,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Synthetic original source"},"subject":"computer","title":"Synthetic book"}"#

    private func legacy() throws -> HandbookCardPackage { try HandbookCardPackage.load(Data(legacyJSON.utf8)) }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func page(_ number: Int = 1, hash: String = "b") -> HandbookCardPackage.Page {
        .init(number: number, asset: .init(sha256: String(repeating: hash, count: 64), mimeType: "image/png",
            byteCount: 100, pixelWidth: 10, pixelHeight: 10, crop: .init(x: 0, y: 0, width: 1, height: 1), altText: "Synthetic original page"))
    }
    private func source(_ id: String, pages: [Int] = [1], imageHash: String = "b") -> HandbookCardPackage.AdditionalSource {
        .init(id: id, source: .init(title: "Synthetic lecture \(id)", fileName: "\(id).pdf", sha256: String(repeating: "c", count: 64),
            pdfPageCount: 3, includedPages: pages), sourcePages: pages.map { page($0, hash: imageHash) })
    }
    private func package(originalPages: [Int] = [1], references: [HandbookCard.SourceReference]? = [.init(sourceID: "D09", page: 1)],
                         sources: [HandbookCardPackage.AdditionalSource]? = nil) throws -> HandbookCardPackage {
        let old = try legacy(), card = old.cards[0]
        return .init(id: old.id, subject: old.subject, title: old.title, revision: "1.1", source: old.source,
            chapters: old.chapters, cards: [.init(id: card.id, sourceGroupIDs: card.sourceGroupIDs, topicNumber: card.topicNumber,
                title: card.title, prompt: card.prompt, answerSummary: card.answerSummary, blocks: card.blocks,
                sourcePages: originalPages, examples: card.examples, sourceNotes: card.sourceNotes, chapterID: card.chapterID,
                sourceReferences: references)], sourcePages: [page(hash: "a")], additionalSources: sources ?? [source("D09")])
    }
    private func edited(_ original: HandbookCardPackage, _ edit: (inout [String: Any]) -> Void) throws -> HandbookCardPackage {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        edit(&object)
        return try HandbookCardPackage.load(JSONSerialization.data(withJSONObject: object))
    }
    private func editedSource(_ original: HandbookCardPackage, _ edit: (inout [String: Any]) -> Void) throws -> HandbookCardPackage {
        try edited(original) { object in
            var sources = object["additionalSources"] as! [[String: Any]]
            var source = sources[0]["source"] as! [String: Any]; edit(&source)
            sources[0]["source"] = source; object["additionalSources"] = sources
        }
    }

    func testLegacyJSONAndDefinitionHashAreByteIdentical() throws {
        let old = try legacy()
        XCTAssertNil(old.additionalSources); XCTAssertNil(old.cards[0].sourceReferences)
        XCTAssertEqual(try canonical(old), Data(legacyJSON.utf8))
        XCTAssertEqual(old.cards[0].definitionID, "d15eeee61af5117bf546fb1fb292c05e884fba142a53d0adcaefb7d7929a961b")
        XCTAssertEqual(old.hash, "fc159af9cf87655672fa94eb447b06c9c24e45574b4993d068ed3efdc2e10084")
        let engine = try HandbookRecallEngine.fresh(old)
        let version = try XCTUnwrap(engine.record.contentVersions.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(version)) as? [String: Any])
        XCTAssertNil(object["additionalSources"])
        let restored = try JSONDecoder().decode(HandbookCardRecord.self, from: canonical(engine.record))
        XCTAssertEqual(try HandbookRecallEngine(package: old, record: restored).record, engine.record)
    }

    func testSamePageNumberKeepsEachSourceAndAssetDistinct() throws {
        let references: [HandbookCard.SourceReference] = [.init(sourceID: "D09", page: 1), .init(sourceID: "D22", page: 1)]
        let pack = try package(references: references, sources: [source("D09", imageHash: "b"), source("D22", imageHash: "c")])
        XCTAssertNoThrow(try pack.validate())
        let decoded = try HandbookCardPackage.load(canonical(pack))
        XCTAssertEqual(decoded, pack); XCTAssertEqual(decoded.cards[0].sourceReferences, references)
        XCTAssertEqual(decoded.cards[0].sourcePages, [1])
        let assets = [decoded.sourcePages![0].asset] + decoded.additionalSources!.map { $0.sourcePages![0].asset }
        XCTAssertEqual(Set(assets.map(\.sha256)).count, 3)
        let changed = try package(references: [.init(sourceID: "D22", page: 1)], sources: pack.additionalSources)
        let firstOnly = try package(sources: pack.additionalSources)
        XCTAssertNotEqual(changed.cards[0].definitionID, firstOnly.cards[0].definitionID)
    }

    func testOnlyAdditionalSourceIsValidAndImagesRemainOptional() throws {
        var lecture = source("D09"); lecture.sourcePages = nil
        let pack = try package(originalPages: [], sources: [lecture])
        XCTAssertNoThrow(try pack.validate())
        XCTAssertEqual(try HandbookCardPackage.load(canonical(pack)), pack)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(lecture)) as? [String: Any])
        XCTAssertNil(encoded["sourcePages"])
        let emptyReferences: [[HandbookCard.SourceReference]?] = [nil, []]
        for references in emptyReferences {
            XCTAssertThrowsError(try package(originalPages: [], references: references).validate())
        }
    }

    func testUnknownOutOfRangeAndDuplicateReferencesAreRejected() throws {
        let invalid: [[HandbookCard.SourceReference]] = [
            [.init(sourceID: "missing", page: 1)], [.init(sourceID: "", page: 1)],
            [.init(sourceID: "D09", page: 0)], [.init(sourceID: "D09", page: -1)],
            [.init(sourceID: "D09", page: 2)], [.init(sourceID: "D09", page: 4)],
            [.init(sourceID: "D09", page: 1), .init(sourceID: "D09", page: 1)]
        ]
        for references in invalid {
            XCTAssertThrowsError(try package(references: references).validate(), "\(references)")
        }
        // Page 2 exists in both the original handbook and D22, but neither can satisfy D09's reference.
        XCTAssertThrowsError(try package(references: [.init(sourceID: "D09", page: 2)],
            sources: [source("D09"), source("D22", pages: [2])]).validate())
        var missingSources = try package(); missingSources.additionalSources = nil
        XCTAssertThrowsError(try missingSources.validate())
        XCTAssertThrowsError(try package(originalPages: [3]).validate())
        XCTAssertThrowsError(try package(originalPages: [1, 1]).validate())
    }

    func testDuplicateAndInvalidSourceIDsAreRejected() throws {
        XCTAssertThrowsError(try package(sources: [source("D09"), source("D09", pages: [2])]).validate())
        for id in ["", " ", " D09", "D09 ", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try package(references: [.init(sourceID: id, page: 1)], sources: [source(id)]).validate())
        }
    }

    func testAdditionalSourceMetadataUsesOriginalSourceValidation() throws {
        let pack = try package()
        for (key, value) in [("sha256", "invalid"), ("title", " "), ("fileName", "../lecture.pdf")] {
            XCTAssertThrowsError(try editedSource(pack) { $0[key] = value })
        }
        let invalidPages: [(String, Any)] = [("pdfPageCount", 0), ("includedPages", [] as [Int]),
                                            ("includedPages", [0]), ("includedPages", [4]), ("includedPages", [1, 1])]
        for (key, value) in invalidPages {
            XCTAssertThrowsError(try editedSource(pack) { $0[key] = value })
        }
    }

    func testAdditionalPageRangesDuplicatesAndAssetMetadataAreValidated() throws {
        let pack = try package()
        for number in [0, 2, 4] {
            var invalid = source("D09"); invalid.sourcePages = [page(number)]
            XCTAssertThrowsError(try package(sources: [invalid]).validate())
        }
        var duplicate = source("D09"); duplicate.sourcePages = [page(), page()]
        XCTAssertThrowsError(try package(sources: [duplicate]).validate())
        let invalidAssets: [(String, Any)] = [("sha256", "invalid"), ("byteCount", 0), ("pixelWidth", 0),
                                            ("mimeType", "text/plain"), ("altText", " "),
                                            ("crop", ["x": 0, "y": 0, "width": 2, "height": 1])]
        for (key, value) in invalidAssets {
            XCTAssertThrowsError(try edited(pack) { object in
                var sources = object["additionalSources"] as! [[String: Any]]
                var pages = sources[0]["sourcePages"] as! [[String: Any]]
                var asset = pages[0]["asset"] as! [String: Any]; asset[key] = value
                pages[0]["asset"] = asset; sources[0]["sourcePages"] = pages; object["additionalSources"] = sources
            })
        }
    }

    func testOldExampleSourcePageStillMeansOriginalHandbook() throws {
        let pack = try package(originalPages: [], references: [.init(sourceID: "D09", page: 3)], sources: [source("D09", pages: [3])])
        XCTAssertThrowsError(try edited(pack) { object in
            var cards = object["cards"] as! [[String: Any]]
            cards[0]["examples"] = [["title": "Synthetic example", "prompt": "Synthetic prompt", "steps": [],
                                     "answer": "Synthetic answer", "sourcePage": 3]]
            object["cards"] = cards
        })
    }

    func testLegacyRecallVersionsKeepTheirOwnSourceDeclarations() throws {
        var engine = try HandbookRecallEngine.fresh(legacy())
        try engine.start(now: now); let token = try XCTUnwrap(engine.presentation?.id)
        try engine.reveal(token: token, now: now); try engine.rate(remembered: false, token: token, now: now)
        let before = engine.record, updated = try package()
        try engine.updatePackage(updated)
        XCTAssertEqual(engine.record.progress, before.progress); XCTAssertEqual(engine.record.ratings, before.ratings)
        XCTAssertEqual(engine.record.events, before.events); XCTAssertEqual(engine.record.cardOrder, before.cardOrder)
        XCTAssertEqual(engine.record.definitions[try legacy().cards[0].definitionID], try legacy().cards[0])
        XCTAssertNil(engine.record.contentVersions[0].additionalSources)
        XCTAssertEqual(engine.record.contentVersions[1].additionalSources, updated.additionalSources)
        let decoded = try JSONDecoder().decode(HandbookCardRecord.self, from: canonical(engine.record))
        XCTAssertEqual(try HandbookRecallEngine(package: updated, record: decoded).record, engine.record)
        var missing = decoded; missing.contentVersions[1].additionalSources = nil
        XCTAssertThrowsError(try HandbookRecallEngine(package: updated, record: missing))
        var duplicate = decoded; duplicate.contentVersions[1].additionalSources = [source("D09"), source("D09")]
        XCTAssertThrowsError(try HandbookRecallEngine(package: updated, record: duplicate))
    }

    @MainActor func testWordContentUpdatePreservesLiveRecordSlotsAndFrozenCard() async throws {
        let engine = try HandbookWordEngine(package: legacy(), now: now)
        try engine.start(now: now); let token = try XCTUnwrap(engine.presentation?.id)
        try engine.reveal(token: token, now: now); try engine.rate(remembered: false, token: token, now: now)
        let nextToken = try XCTUnwrap(engine.presentation?.id); try engine.reveal(token: nextToken, now: now)
        let before = engine.state, face = engine.presentation
        try engine.updatePackage(package(), now: now)
        XCTAssertEqual(engine.record, before.word)
        XCTAssertEqual(engine.state.originalCardIDs, before.originalCardIDs)
        XCTAssertEqual(engine.currentCard, before.frozenCard); XCTAssertEqual(engine.presentation, face)
        let decoded = try JSONDecoder().decode(HandbookWordState.self, from: canonical(engine.state))
        XCTAssertEqual(try HandbookWordEngine(state: decoded).state, engine.state)
    }
}
