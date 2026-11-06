#if DEBUG
import SwiftUI
import Foundation

/// All preview values and their backing files are synthetic and isolated in
/// this simulator app's temporary directory, never in personal study storage.
@MainActor private final class EffectiveTimePreviewFixture: ObservableObject {
    let root: URL
    let store: EffectiveStudyTimeStore
    let previewCase: String
    let captureID: String
    let today: Date
    let expectedToday: [EffectiveStudyArea: Double]

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let selected = value("--case") ?? "home"
        precondition(["home", "records"].contains(selected), "Unknown synthetic time preview")
        guard let rawID = value("--capture-id"), let uuid = UUID(uuidString: rawID),
              uuid.uuidString.lowercased() == rawID else { preconditionFailure("Missing synthetic capture UUID") }
        previewCase = selected
        captureID = rawID
        let previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-effective-time-" + uuid.uuidString.lowercased(), isDirectory: true)
        let previewToday = Date()
        let expected: [EffectiveStudyArea: Double] = [.vocabulary: 125, .publicQuestions: 67, .math: 300, .computer: 580,
                                                       .power: 725, .circuit: 460, .mechanics: 180]
        root = previewRoot
        today = previewToday
        expectedToday = expected
        do {
            try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: false)
            let folder = previewRoot.appendingPathComponent("EffectiveStudyTime", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            func key(_ day: Date) -> String {
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
            var state = EffectiveStudyTimeState()
            state.days[key(previewToday)] = Dictionary(uniqueKeysWithValues: expected.map { ($0.key.rawValue, $0.value) })
            let yesterday = calendar.date(byAdding: .day, value: -1, to: previewToday)!
            state.days[key(yesterday)] = [EffectiveStudyArea.vocabulary.rawValue: 45,
                                          EffectiveStudyArea.power.rawValue: 120,
                                          EffectiveStudyArea.mechanics.rawValue: 30]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: folder.appendingPathComponent("current.json"), options: .atomic)
            let previewStore = EffectiveStudyTimeStore(baseDirectory: previewRoot)
            precondition(!previewStore.blocked && previewStore.error == nil && !previewStore.isCounting)
            for area in EffectiveStudyArea.allCases {
                precondition(previewStore.seconds(for: area, on: previewToday) == expected[area])
            }
            store = previewStore
        } catch { fatalError("Synthetic effective-time fixture failed: \(error)") }
    }
}

struct EffectiveStudyTimePreview: View {
    @StateObject private var fixture: EffectiveTimePreviewFixture
    @State private var receiptWritten = false

    @MainActor init() {
        _fixture = StateObject(wrappedValue: EffectiveTimePreviewFixture())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("纯合成预览 · 不含个人记录").font(.caption).foregroundStyle(.secondary)
                    EffectiveStudyTimeSummary(store: fixture.store, allowDateSelection: fixture.previewCase == "records")
                        .padding(18)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { reportIfReady(geometry.size) }
                                    .onChange(of: geometry.size) { _, size in reportIfReady(size) }
                            }
                        }
                }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(fixture.previewCase == "records" ? "记录预览" : "今天预览")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @MainActor private func reportIfReady(_ size: CGSize) {
        guard !receiptWritten, size.width > 0, size.height > 0, !fixture.store.blocked,
              fixture.store.error == nil, EffectiveStudyArea.allCases.count == 7 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !receiptWritten, !fixture.store.blocked else { return }
            let today = Dictionary(uniqueKeysWithValues: EffectiveStudyArea.allCases.map {
                ($0.rawValue, fixture.store.seconds(for: $0, on: fixture.today))
            })
            guard today.count == fixture.expectedToday.count,
                  fixture.expectedToday.allSatisfy({ today[$0.key.rawValue] == $0.value }) else { return }
            let payload: [String: Any] = ["suite": "effective-time", "case": fixture.previewCase,
                "captureID": fixture.captureID, "ready": true, "syntheticOnly": true,
                "areaCount": today.count, "todaySeconds": today,
                "todayTotalSeconds": today.values.reduce(0, +), "idleLimitSeconds": EffectiveStudyTimeStore.idleLimit,
                "counting": fixture.store.isCounting, "layoutWidth": size.width, "layoutHeight": size.height]
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("effective-time-preview-ready-" + fixture.captureID + ".json")
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                try data.write(to: target, options: .atomic)
                receiptWritten = true
            } catch { print("Synthetic effective-time preview receipt failed: \(error.localizedDescription)") }
        }
    }
}
#endif
