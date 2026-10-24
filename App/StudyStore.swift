import Foundation
import Combine
import StudyCore
import CPocket

@MainActor
final class StudyStore: ObservableObject {
    @Published private(set) var deck: WordDeck?
    @Published private(set) var info = xkl_info_t()
    @Published private(set) var sessionStarted = false
    @Published private(set) var dueTodayCount = 0
    @Published private(set) var supplementVisible = false
    @Published private(set) var ownership: SyncOwnership = .inactive
    @Published private(set) var pendingPeer: DeviceHello?
    @Published private(set) var paired = false
    @Published private(set) var syncStatus = "连接后先核对词库和学习记录版本"
    @Published private(set) var conflictCount = 0
    @Published private(set) var hasArchive = false
    @Published private(set) var analysis: StudyAnalysisSettings?
    @Published private(set) var shadowReport: DualFSRSReport?
    @Published private(set) var timing: StudyTimingJournal?
    @Published private(set) var history: StudyArchiveIndex?
    @Published private(set) var annotations=StudyAnnotations()
    @Published private(set) var feedbackPrompt: StudyFeedbackPrompt?
    @Published var selectedMissingMeanings=Set<Int>()
    @Published private(set) var shadowStatus = "FSRS 只作后台比较，不调整实际日期"
    @Published var error: String?
    let bluetooth = BluetoothLink()

    private var engine: PocketEngine?
    private var coordinator: SyncCoordinator?
    private var pairedPeripherals: [String: String] = [:]
    private var provisioningSnapshot: Data?
    private let directory: URL
    private var handshakeTimer: Timer?
    private var fatalStorageError = false
    private var legacyBackupPending = false
    private var legacyBackupSHA256: String?
    private var shadowTask: Task<Void, Never>?
    private var shadowGeneration: UInt64 = 0
    private var activityClock=StudyActivityClock()
    private var studyScreenVisible=false
    private var timingUpgradePending=false
    private var timingBackupSHA256: String?
    private var historyBackupSHA256: String?
    private var historyUpgradePending=false
    private var priorEvents: [StudyEvent]=[]
    private var priorTiming: StudyTimingJournal?
    private var contentSHA256: String?
    private var contentRevisions: [ContentRevision] = []

    var currentWord: StudyWord? {
        guard sessionStarted, info.has_task != 0, let deck, Int(info.word) < deck.words.count else { return nil }
        return deck.words[Int(info.word)]
    }
    var canLearn: Bool { coordinator != nil && ownership == .active && !fatalStorageError }
    var canHandoff: Bool { canLearn && (history?.volumes.isEmpty ?? true) && paired && bluetooth.ready && pendingPeer != nil && coordinator?.state.pending == nil }
    var hasPendingTransfer: Bool { coordinator?.state.pending != nil }
    var activeVolumeEvents: UInt32 { engine?.volumeRecords ?? 0 }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Study", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            hasArchive = FileManager.default.fileExists(atPath: archiveURL.path)
            if FileManager.default.fileExists(atPath: contentURL.path) {
                try loadContent(Data(contentsOf: contentURL))
            } else if let data = try PersonalContent.bundled() {
                try loadContent(data)
            }
        } catch {
            self.error = error.localizedDescription
            fatalStorageError = hasArchive
        }
        bluetooth.onReady = { [weak self] in self?.sendHello() }
        bluetooth.onMessage = { [weak self] message in self?.receive(message) }
        bluetooth.onDisconnected = { [weak self] in
            guard let self else { return }
            self.handshakeTimer?.invalidate()
            self.pendingPeer = nil
            self.paired = false
            if self.hasPendingTransfer { self.syncStatus = "接力未确认，已保持锁定。重连同一设备后继续核对。" }
        }
    }

    private var archiveURL: URL { directory.appendingPathComponent("study-state-v1.json") }
    private var contentURL: URL { directory.appendingPathComponent("personal-content.xklcontent") }
    private var volumesURL: URL { directory.appendingPathComponent("volumes",isDirectory:true) }

    func importContent(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= PersonalContent.maximumFileBytes else {
                throw StudyError.invalidResource("内容包超过 40MB 或无法读取。")
            }
            let data = try Data(contentsOf: url)
            let (content, _) = try PersonalContent.load(data)
            _ = try PocketEngine(seed: content.personalState, stream: UUID())
            try ContentImportTransaction.perform(prepare: {
                // Keep exact old content and archive bytes before a content-only update.
                for (source, prefix, suffix) in [(contentURL,"content-",".xklcontent"),(archiveURL,"pre-content-",".json")] {
                    if FileManager.default.fileExists(atPath:source.path) {
                        let original=try Data(contentsOf:source)
                        let backup=directory.appendingPathComponent("\(prefix)\(sha256(original))\(suffix)")
                        if FileManager.default.fileExists(atPath:backup.path) {
                            guard try Data(contentsOf:backup)==original else { throw StudyError.persistence("内容更新前备份校验失败。") }
                        } else { try DurableFile.write(original,to:backup) }
                    }
                }
            }, writeContent: {
                try DurableFile.write(data, to: contentURL)
            }, activateContent: {
                // Existing study state always wins over the imported seed.
                try loadContent(data)
            }, persistBoundary: {
                guard let coordinator else { throw StudyError.persistence("释义更新后的学习状态尚未载入。") }
                // Preserve snapshot and grades; only append the content boundary.
                try persist(try JSONEncoder().encode(coordinator.state))
            }, onCommitFailure: {
                pauseAfterContentImportFailure()
            })
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func pauseAfterContentImportFailure() {
        fatalStorageError = true
        sessionStarted = false
        supplementVisible = false
        selectedMissingMeanings.removeAll()
        activityClock.running = false
        shadowTask?.cancel()
        shadowGeneration &+= 1
        shadowReport = nil
        shadowStatus = "释义更新状态需要核对，后台比较已暂停"
        syncStatus = "释义更新未完成，请重新打开应用核对已保存的内容和学习记录。"
    }

    private func loadContent(_ data: Data) throws {
        let (content, loadedDeck) = try PersonalContent.load(data)
        let newEngine: PocketEngine
        let newCoordinator: SyncCoordinator
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let record = try JSONDecoder().decode(AppDiskRecord.self, from: Data(contentsOf: archiveURL))
            guard (1...4).contains(record.format) else { throw StudyError.persistence("学习记录格式未知，已保留原文件。") }
            let state = try JSONDecoder().decode(SyncState.self, from: record.syncStateJSON)
            guard state.deckVersion == loadedDeck.version, state.algorithm == 3, state.schema == 7,
                  state.profileID == PersonalContent.baselineHash else {
                throw StudyError.persistence("学习记录与当前内容包不同，已停止载入。")
            }
            newCoordinator = try makeCoordinator(state)
            newEngine = try PocketEngine(snapshot: state.snapshot)
            contentRevisions = try ContentRevision.reconciled(record.contentRevisions,
                incoming:content.manifest.deckSHA256,logCount:newEngine.info.log_records,existingArchive:true)
            analysis = try record.validatedAnalysis(engine: newEngine)
            legacyBackupPending = record.format == 1
            legacyBackupSHA256 = record.legacyBackupSHA256
            timing=try record.validatedTiming(engine:newEngine)
            timingUpgradePending=record.format<3
            timingBackupSHA256=record.timingBackupSHA256
            try restoreHistory(record,engine:newEngine)
            resetActivityClock(after:try newEngine.info.log_records)
            pairedPeripherals = record.pairedPeripherals
            if let initial = record.provisioningSnapshot {
                _ = try PocketEngine(snapshot: initial)
                provisioningSnapshot = initial
            }
        } else {
            newEngine = try PocketEngine(seed: content.personalState, stream: UUID())
            analysis = StudyAnalysisSettings(streamID: try newEngine.streamID, nextSequence: try newEngine.info.log_records + 1)
            timing=StudyTimingJournal(streamID:try newEngine.streamID,firstSequence:try newEngine.info.log_records+1)
            history=StudyArchiveIndex(streamID:try newEngine.streamID)
            resetActivityClock(after:try newEngine.info.log_records)
            let initial = try newEngine.snapshot()
            contentRevisions = try ContentRevision.reconciled(nil,incoming:content.manifest.deckSHA256,
                logCount:newEngine.info.log_records,existingArchive:false)
            provisioningSnapshot = initial
            let state = try SyncState.initial(profileID: PersonalContent.baselineHash,
                                              deviceID: UUID().uuidString.lowercased(),
                                              deckVersion: loadedDeck.version, algorithm: 3, schema: 7,
                                              snapshot: initial, active: true)
            newCoordinator = try makeCoordinator(state)
            try persist(try JSONEncoder().encode(state))
        }
        deck = loadedDeck
        contentSHA256 = content.manifest.deckSHA256
        engine = newEngine
        coordinator = newCoordinator
        hasArchive = true
        sessionStarted = false
        supplementVisible = false
        fatalStorageError = false
        try refresh()
        refreshShadow()
    }

    private func makeCoordinator(_ state: SyncState) throws -> SyncCoordinator {
        try SyncCoordinator(state: state, snapshotValidator: { data in
            _ = try PocketEngine(snapshot: data)
        })
    }

    func start(date: Date) {
        guard canLearn else { return }
        do {
            let day = try Self.studyDay(date)
            guard day >= info.day else { throw StudyError.engine("所选日期早于已有学习记录，请核对日期。") }
            // Resuming an in-process task retains its exact visible step. On a
            // cold launch, rebase the runtime clock and restore an already
            // revealed answer only within the same study day.
            if sessionStarted, info.has_task != 0, day == info.day, day == info.selection_day { return }
            try mutate { try $0.start(day: day, preservingRevealedAnswer: true,
                                     preservingShownStepAcrossDay: true) }
            sessionStarted = true
            refreshActivity(reason:"task-start")
        } catch { self.error = error.localizedDescription }
    }

    /// Reconcile today's due queue without discarding the visible learning step.
    /// selection_day also repairs old archives whose clock advanced but queue did not.
    func refreshStudyDate() {
        if let engine, let day = try? Self.studyDay(Date()) { dueTodayCount = engine.dueCount(on: day) }
        guard info.has_task != 0, canLearn else { return }
        do {
            let day = try Self.studyDay(Date())
            guard day >= info.day else { throw StudyError.engine("手机系统日期早于已有学习记录，请检查系统日期后继续。") }
            guard day != info.day || day != info.selection_day else { return }
            try mutate { try $0.start(day: day, preservingRevealedAnswer: true,
                                     preservingShownStepAcrossDay: true) }
            sessionStarted = true
            refreshActivity(reason: "calendar-due-refresh")
        } catch {
            self.error = error.localizedDescription
            sessionStarted = false
            supplementVisible = false
        }
    }

    func reveal() {
        guard sessionStarted else { return }
        refreshStudyDate()
        guard sessionStarted, error == nil else { return }
        run { try mutate { try $0.reveal() } }
    }
    func answer(_ value: Int32) {
        guard sessionStarted, !supplementVisible else { return }
        refreshStudyDate()
        guard sessionStarted, error == nil else { return }
        run {
            try mutate { engine in
                guard let settings = analysis else { throw AnalysisError.invalidSettings }
                if let decision = try engine.answer(value, policy: settings) { analysis?.reductions.append(decision) }
            }
        }
    }
    func beginSupplement() {
        refreshStudyDate()
        guard canLearn, sessionStarted, info.revealed != 0 else { return }
        selectedMissingMeanings=[]
        supplementVisible = true
    }
    func confirmSupplement() {
        guard supplementVisible else { return }
        refreshStudyDate()
        guard supplementVisible, error == nil else { return }
        do {
            let word=info.word, count=currentWord?.core.count ?? 0, selected=selectedMissingMeanings.sorted()
            try mutate { try $0.answer(3) }
            // The grade is already durable. Optional annotation failure must not
            // repeat the grade; report it independently and preserve the answer.
            if let engine,let event=try engine.events(from:engine.logBase+1).last(where:{$0.kind==10 && $0.word==word}),count>0 {
                var omission=MeaningOmission(sequence:event.sequence,word:word,deckVersion:WordDeck.expectedVersion,
                                             coreCount:count,indices:selected.isEmpty ? nil:selected)
                omission.contentSHA256=contentSHA256
                annotations.omissions.append(omission)
                saveMetadata()
            }
            supplementVisible = false
        } catch { self.error = error.localizedDescription }
    }
    func cancelSupplement() { supplementVisible = false }
    func undoFamiliar() {
        guard sessionStarted else { return }
        refreshStudyDate()
        guard sessionStarted, error == nil else { return }
        run { try mutate { try $0.undo() } }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    private func mutate(_ operation: (PocketEngine) throws -> Void) throws {
        try rotateIfNeeded()
        guard canLearn, let engine else { throw StudyError.engine("学习已暂停，先完成接力确认。") }
        let beforeInfo=try engine.info
        let before = try engine.snapshot()
        let beforeAnalysis = analysis
        let beforeTiming=timing
        let firstNew=try engine.info.log_records+1
        do {
            try operation(engine)
            let point=timePoint()
            let appended=try engine.events(from:firstNew)
            timing?.capture(appended,at:point,running:activityClock.running)
            if let first=shadowFirstSequence,let journal=timing {
                let events=try allEvents()
                let completeTiming=StudyHistoryFiles.merge(priorTiming,journal)
                for presentation in appended where presentation.kind==3 {
                    // A comparison failure cannot cancel a real learning action.
                    if let forecast=try? DualFSRSReport.makeForecast(events:events,timing:completeTiming,
                            firstSequence:first,presentation:presentation) { timing?.forecasts.append(forecast) }
                }
            }
            let afterInfo=try engine.info
            if beforeInfo.has_task != 0 && afterInfo.has_task==0 {
                feedbackPrompt=StudyFeedbackPrompt(taskID:"\(try engine.streamID):\(afterInfo.revision)",
                    sequence:afterInfo.log_records,day:afterInfo.day,lesson:afterInfo.lesson)
            } else if beforeInfo.has_task==0 && afterInfo.has_task != 0 { feedbackPrompt=nil }
            try apply(.localSnapshot(try engine.snapshot()))
            try refresh()
            refreshActivity(reason:"task-state")
            refreshShadow()
        } catch {
            // No visible card advancement occurs until the entire state + ownership
            // journal has reached the same atomic file.
            do {
                // An I/O operation can fail after the atomic rename. Read the actual
                // durable file before deciding which version is authoritative.
                if FileManager.default.fileExists(atPath: archiveURL.path) { try restoreDurableState() }
                else { self.engine = try PocketEngine(snapshot: before); analysis = beforeAnalysis; timing=beforeTiming; resetActivityClock() }
                try refresh()
            }
            catch { fatalStorageError = true }
            throw error
        }
    }

    private func persist(_ stateData: Data) throws {
        guard let analysis,let timing,let history else { throw AnalysisError.invalidSettings }
        let state=try JSONDecoder().decode(SyncState.self,from:stateData)
        let persistedEngine=try PocketEngine(snapshot:state.snapshot)
        try analysis.validate(streamID:persistedEngine.streamID,logCount:persistedEngine.info.log_records)
        try timing.validate(streamID:persistedEngine.streamID,logCount:persistedEngine.info.log_records)
        try history.validate(streamID:persistedEngine.streamID,activeBase:persistedEngine.logBase,logCount:persistedEngine.info.log_records)
        try annotations.validate(logCount:persistedEngine.info.log_records)
        if historyUpgradePending {
            let original=try Data(contentsOf:archiveURL)
            let hash=sha256(original)
            let backup=directory.appendingPathComponent("pre-history-\(hash).json")
            if FileManager.default.fileExists(atPath:backup.path) {
                guard try Data(contentsOf:backup)==original else { throw StudyError.persistence("分卷升级前备份校验失败。") }
            } else { try DurableFile.write(original,to:backup) }
            historyBackupSHA256=hash;historyUpgradePending=false
        }
        if timingUpgradePending {
            let original=try Data(contentsOf:archiveURL)
            let hash=sha256(original),backup=directory.appendingPathComponent("pre-timing-\(sha256(original)).json")
            if FileManager.default.fileExists(atPath:backup.path) {
                guard try Data(contentsOf:backup)==original else { throw StudyError.persistence("时间记录升级前备份校验失败。") }
            } else { try DurableFile.write(original,to:backup) }
            timingBackupSHA256=hash;timingUpgradePending=false
        }
        if legacyBackupPending {
            let original = try Data(contentsOf: archiveURL)
            let hash = sha256(original)
            let backup = directory.appendingPathComponent("pre-policy-\(hash).json")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == original else { throw StudyError.persistence("升级前备份校验失败，已停止保存。") }
            } else { try DurableFile.write(original, to: backup) }
            legacyBackupSHA256 = hash
            legacyBackupPending = false
        }
        let record = AppDiskRecord(format: 4, syncStateJSON: stateData,
                                   pairedPeripherals: pairedPeripherals,
                                   provisioningSnapshot: provisioningSnapshot, savedAt: Date(),
                                   analysis: analysis, legacyBackupSHA256: legacyBackupSHA256,
                                   timing:timing,timingBackupSHA256:timingBackupSHA256,
                                   history:history,historyBackupSHA256:historyBackupSHA256,
                                   annotations:annotations,feedbackPrompt:feedbackPrompt,contentRevisions:contentRevisions)
        let data = try JSONEncoder().encode(record)
        try DurableFile.write(data, to: archiveURL)
    }

    private func apply(_ input: SyncInput) throws {
        guard !fatalStorageError else { throw StudyError.persistence("请重新打开应用核对已保存的学习记录，再继续学习或接力。") }
        guard var coordinator else { throw StudyError.sync("请先导入词库与学习记录。") }
        let transition = try coordinator.propose(input)
        let effects: SyncEffects
        do {
            try persist(transition.encodedState)
            effects = try coordinator.acknowledgePersistence(transition, persistedState: transition.encodedState)
            self.coordinator = coordinator
            if let activated = effects.activationSnapshot {
                engine = try PocketEngine(snapshot: activated)
                sessionStarted = false
                supplementVisible = false
                refreshShadow()
            }
            try refresh()
        }
        catch {
            // Failure may be after rename. Do not keep using an in-memory active
            // state when the journal might already contain a persisted sender lock.
            fatalStorageError = true
            sessionStarted = false
            do { try restoreDurableState() } catch { /* Remain blocked; retain the file for recovery. */ }
            syncStatus = "学习记录写入状态需要核对，请重新打开应用。原记录没有被清空。"
            throw error
        }
        // Transmission errors cannot roll back a persisted sender lock or COMMIT.
        for message in effects.outgoing {
            do { try bluetooth.send(.sync(message)) }
            catch { syncStatus = "状态已保存，蓝牙发送未完成。重连后继续核对。"; self.error = error.localizedDescription }
        }
        updateSyncStatus()
    }

    private func restoreDurableState() throws {
        let record = try JSONDecoder().decode(AppDiskRecord.self, from: Data(contentsOf: archiveURL))
        let state = try JSONDecoder().decode(SyncState.self, from: record.syncStateJSON)
        guard (1...4).contains(record.format), state.profileID == PersonalContent.baselineHash,
              state.deckVersion == WordDeck.expectedVersion else { throw StudyError.persistence("学习记录身份校验失败。") }
        let restored = try makeCoordinator(state)
        let restoredEngine = try PocketEngine(snapshot: state.snapshot)
        contentRevisions = try ContentRevision.reconciled(record.contentRevisions,
            incoming:contentSHA256 ?? PersonalContent.deckHash,logCount:restoredEngine.info.log_records,existingArchive:true)
        analysis = try record.validatedAnalysis(engine: restoredEngine)
        legacyBackupPending = record.format == 1
        legacyBackupSHA256 = record.legacyBackupSHA256
        timing=try record.validatedTiming(engine:restoredEngine)
        timingUpgradePending=record.format<3
        timingBackupSHA256=record.timingBackupSHA256
        try restoreHistory(record,engine:restoredEngine)
        resetActivityClock(after:try restoredEngine.info.log_records)
        if let initial = record.provisioningSnapshot { _ = try PocketEngine(snapshot: initial) }
        self.coordinator = restored
        engine = restoredEngine
        pairedPeripherals = record.pairedPeripherals
        provisioningSnapshot = record.provisioningSnapshot
        try refresh()
    }

    private func refresh() throws {
        if let engine {
            info = try engine.info
            if let day = try? Self.studyDay(Date()) { dueTodayCount = engine.dueCount(on: day) }
        }
        ownership = coordinator?.state.ownership ?? .inactive
        conflictCount = coordinator?.state.conflicts.count ?? 0
    }

    private var localHello: DeviceHello? {
        guard let state = coordinator?.state,history?.volumes.isEmpty ?? true else { return nil }
        return DeviceHello(protocolVersion: 1, deviceID: state.deviceID, profileID: state.profileID,
                           deckVersion: state.deckVersion, algorithm: state.algorithm, schema: state.schema,
                           learningPolicyVersion: 1,contentSHA256:contentSHA256)
    }

    private func sendHello() {
        if !(history?.volumes.isEmpty ?? true) {
            bluetooth.disconnect();error="已有分卷日志，需要设备端支持完整历史同步；当前设备端尚未适配。";return
        }
        guard let localHello else { bluetooth.disconnect(); error = "请先导入词库与学习记录。"; return }
        run { try bluetooth.send(.handshake(localHello)) }
        handshakeTimer?.invalidate()
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingPeer == nil else { return }
                self.bluetooth.disconnect()
                self.syncStatus = "未收到兼容版本确认，未开始接力。"
            }
        }
    }

    private func receive(_ message: DeviceWireMessage) {
        do {
            switch message.kind {
            case "hello":
                guard message.envelope == nil, let hello = message.hello,
                      let localHello, localHello.compatible(with: hello),
                      let peripheralID = bluetooth.selectedID?.uuidString else {
                    throw StudyError.sync("设备身份、词库或算法版本不匹配，未开始接力。")
                }
                if let remembered = pairedPeripherals[peripheralID], remembered != hello.deviceID {
                    throw StudyError.sync("这个蓝牙设备的学习身份已改变，请重新检查设备。")
                }
                pendingPeer = hello
                handshakeTimer?.invalidate()
                paired = pairedPeripherals[peripheralID] == hello.deviceID &&
                    coordinator?.state.trustedPeerIDs.contains(hello.deviceID) == true
                syncStatus = paired ? "版本一致，已连接已配对设备" : "版本一致，请确认这是你选择的小设备"
                if paired, hasPendingTransfer { try apply(.retry) }
            case "sync":
                guard message.hello == nil, paired, let peer = pendingPeer, let envelope = message.envelope,
                      envelope.sourceDeviceID == peer.deviceID else {
                    throw StudyError.sync("尚未确认配对，未接收学习记录。")
                }
                try apply(.receive(envelope))
            default: throw StudyError.sync("无法识别的同步消息，未修改学习进度。")
            }
        } catch {
            self.error = error.localizedDescription
            syncStatus = "同步未完成，原学习记录已保留"
        }
    }

    func confirmPairing() {
        guard let hello = pendingPeer, let id = bluetooth.selectedID?.uuidString else { return }
        let oldPairs = pairedPeripherals
        pairedPeripherals[id] = hello.deviceID
        do { try apply(.authorizePeer(hello.deviceID)); paired = true; syncStatus = "配对身份已保存，接力还需共同基线校验" }
        catch { pairedPeripherals = oldPairs; self.error = error.localizedDescription }
    }

    func handoffToDevice() {
        guard canHandoff, let peer = pendingPeer else { return }
        run { try apply(.beginHandoff(peerID: peer.deviceID)) }
    }

    func reconcile() {
        guard paired, bluetooth.ready else { error = "请先重新连接同一台已配对设备。"; return }
        run { try apply(.retry) }
    }

    private func updateSyncStatus() {
        guard let state = coordinator?.state else { return }
        if state.lastIssue == "divergent-branch" {
            syncStatus = "两边的学习进度已分叉，没有自动覆盖。请导出双方记录后核对，当前接力保持锁定。"
        } else if state.lastIssue == "receiver-active" {
            syncStatus = "小设备仍持有自己的学习进度，不能直接覆盖。请先核对首次初始化及设备现有记录。"
        } else if state.pending != nil { syncStatus = "正在核对接力。完成确认前暂停学习，断线后可继续。" }
        else if state.ownership == .inactive { syncStatus = "学习已交给小设备。在小设备上确认交回后，iPhone 才能继续。" }
        else if state.ownership == .active { syncStatus = "iPhone 可以继续学习" }
        else { syncStatus = "学习已锁定，等待双方状态核对" }
    }

    func exportRecords() throws -> Data {
        guard let engine, let coordinator else { throw StudyError.engine("还没有可导出的学习记录。") }
        let log = try engine.rawLog()
        let state = try Data(contentsOf: archiveURL)
        var export = RecordsExport(exportedAt: Date(), deckVersion: coordinator.state.deckVersion,
                                   algorithm: 3, checkpointSchema: 7, wordCount: 25_644,
                                   logRecords: info.log_records, rawLog: log, logSHA256: sha256(log),
                                   stateSHA256: sha256(state), durableState: state)
        export.analysis = analysis
        export.timing=timing
        export.history=history;export.annotations=annotations
        export.contentRevisions=contentRevisions;export.currentContentSHA256=contentSHA256
        if let first=shadowFirstSequence,let timing {
            do { export.dualFSRSComparison = try DualFSRSReport.evaluate(events:allEvents(),timing:StudyHistoryFiles.merge(priorTiming,timing),
                        firstSequence:first,coreCounts:coreMeaningCounts) }
            catch { export.comparisonError = String(describing: error) }
        }
        if let hash = legacyBackupSHA256 {
            let original = try Data(contentsOf: directory.appendingPathComponent("pre-policy-\(hash).json"))
            guard sha256(original) == hash else { throw StudyError.persistence("升级前档案校验失败。") }
            export.preservedLegacyArchive = original
        }
        if let hash=timingBackupSHA256 {
            let original=try Data(contentsOf:directory.appendingPathComponent("pre-timing-\(hash).json"))
            guard sha256(original)==hash else { throw StudyError.persistence("升级前时间档案校验失败。") }
            export.preservedPreTimingArchive=original
        }
        if let hash=historyBackupSHA256 {
            let original=try Data(contentsOf:directory.appendingPathComponent("pre-history-\(hash).json"))
            guard sha256(original)==hash else { throw StudyError.persistence("分卷升级前档案校验失败。") }
            export.preservedPreHistoryArchive=original
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    func exportReceiverProvisioning() throws -> Data {
        guard history?.volumes.isEmpty ?? true else { throw StudyError.sync("已有分卷日志，需要支持完整历史的设备协议；当前设备端尚未实现。") }
        guard let state = coordinator?.state, state.canStudy, state.pending == nil,
              let initial = provisioningSnapshot, sha256(initial) == state.baselineHash else {
            throw StudyError.sync("首次接力基线已变化，不能生成旧设备初始化包。已有设备请使用同步接力。")
        }
        _ = try PocketEngine(snapshot: initial)
        let receiverID = UUID().uuidString.lowercased()
        let receiver = try SyncState.initial(profileID: state.profileID, deviceID: receiverID,
                                             deckVersion: state.deckVersion, algorithm: state.algorithm,
                                             schema: state.schema, snapshot: initial, active: false,
                                             trustedPeerIDs: [state.deviceID])
        _ = try makeCoordinator(receiver)
        let document = ReceiverProvisioning(exportedAt: Date(), sourceDeviceID: state.deviceID,
                                             receiverDeviceID: receiverID, receiverState: receiver)
        return try JSONEncoder().encode(document)
    }

    func setConservativeEnabled(_ enabled: Bool) {
        guard canLearn, var settings=analysis, let coordinator else { return }
        guard settings.conservativeEnabled != enabled else { return }
        let before=analysis
        settings.setEnabled(enabled, nextSequence: info.log_records+1)
        analysis=settings
        do {
            try persist(try JSONEncoder().encode(coordinator.state))
            refreshShadow()
        } catch {
            do { try restoreDurableState() } catch { analysis=before }
            fatalStorageError=true
            self.error="设置写入需要核对，请重新打开应用。已有学习记录已保留。"
        }
    }

    private func refreshShadow() {
        shadowTask?.cancel()
        shadowGeneration &+= 1
        let generation=shadowGeneration
        guard let engine, let first=shadowFirstSequence,let timing else { return }
        do {
            let events=try allEvents()
            let completeTiming=StudyHistoryFiles.merge(priorTiming,timing)
            let counts=coreMeaningCounts
            shadowStatus="双 FSRS 后台比较中，实际复习计划不变"
            shadowTask=Task { [weak self] in
                let worker=Task.detached(priority:.utility) { try DualFSRSReport.evaluate(events:events,timing:completeTiming,firstSequence:first,coreCounts:counts) }
                let result=await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.shadowGeneration == generation else { return }
                switch result {
                case .success(let report):
                    self.shadowReport=report
                    self.shadowStatus="当前释义版本内比较；有效延迟首答 \(report.comparableCount) 次"
                case .failure:
                    self.shadowStatus="后台比较暂不可用，原复习计划继续执行"
                }
            }
        } catch { shadowStatus="后台比较暂不可用，原复习计划继续执行" }
    }

    private var coreMeaningCounts: [UInt32:Int] {
        // Shadow rows start at the latest content boundary, so these counts
        // describe those rows; earlier raw answers are never backfilled.
        return Dictionary(uniqueKeysWithValues:(deck?.words ?? []).enumerated().map { (UInt32($0.offset),$0.element.core.count) })
    }
    private var shadowFirstSequence: UInt32? {
        analysis.map { ContentRevision.comparisonFirstSequence(base:$0.shadowFirstSequence,revisions:contentRevisions) }
    }
    private func allEvents() throws -> [StudyEvent] {
        guard let engine else { return [] }
        return priorEvents + (try engine.events(from:engine.logBase+1))
    }
    private func restoreHistory(_ record:AppDiskRecord,engine:PocketEngine) throws {
        let index=try record.validatedHistory(engine:engine)
        let loaded=try StudyHistoryFiles.load(index,directory:volumesURL)
        history=index;priorEvents=loaded.events;priorTiming=loaded.timing
        historyBackupSHA256=record.historyBackupSHA256;historyUpgradePending=record.format<4
        annotations=record.annotations ?? StudyAnnotations();feedbackPrompt=record.feedbackPrompt
    }
    private func rotateIfNeeded() throws {
        guard canLearn,let engine,let coordinator,var index=history,var settings=analysis,var journal=timing else { return }
        guard engine.volumeRecords>=info.log_capacity-64 || journal.boundaries.count>=99_000 else { return }
        // First persist and seal the exact old record. The new active pointer is
        // committed only after its immutable dependency has reached disk.
        try persist(try JSONEncoder().encode(coordinator.state))
        let bytes=try Data(contentsOf:archiveURL),end=try engine.info.log_records
        let ref=try StudyHistoryFiles.seal(bytes,number:index.volumes.count+1,first:engine.logBase+1,last:end,
                                           directory:volumesURL,write:DurableFile.write)
        let previousEvents=try allEvents(),previousTiming=StudyHistoryFiles.merge(priorTiming,journal)
        let next=try engine.rotated(policyFirst:settings.conservativeFirstSequence)
        index.volumes.append(ref)
        settings.archivedSavedRepetitions=settings.savedRepetitions;settings.reductions=[]
        journal.events=[];journal.boundaries=[];journal.forecasts=[];journal.boundaryLimitReached=false
        journal.boundary(after:end,point:timePoint(),visible:activityClock.running,
                         word:info.has_task != 0 ? info.word:nil,answerVisible:info.revealed != 0,reason:"volume-open; no new presentation")
        history=index;analysis=settings;timing=journal;annotations=StudyAnnotations()
        do {
            try apply(.localSnapshot(next.snapshot()))
            self.engine=next;priorEvents=previousEvents;priorTiming=previousTiming
            try refresh()
        } catch {
            try? restoreDurableState()
            throw error
        }
    }
    private func saveMetadata() {
        guard !fatalStorageError, let coordinator else { return }
        do { try persist(try JSONEncoder().encode(coordinator.state)) }
        catch { try? restoreDurableState();self.error="选填记录保存未完成；已保存的学习评分保持不变。" }
    }
    func saveTaskFeedback(annoyance:Int?,fatigue:Int?) {
        guard !fatalStorageError, let prompt=feedbackPrompt,[annoyance,fatigue].allSatisfy({$0 == nil || (0...10).contains($0!)}) else { return }
        annotations.feedback.removeAll { $0.task.taskID==prompt.taskID }
        annotations.feedback.append(StudyTaskFeedback(task:prompt,annoyance:annoyance,fatigue:fatigue))
        feedbackPrompt=nil;saveMetadata()
    }
    func skipTaskFeedback() { guard !fatalStorageError else { return };feedbackPrompt=nil;saveMetadata() }
    func exportFullArchive() throws -> URL {
        guard let history else { throw AnalysisError.invalidSettings }
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("study-export-\(UUID().uuidString).zip")
        let lines=FileManager.default.temporaryDirectory.appendingPathComponent("study-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at:lines) }
        guard FileManager.default.createFile(atPath:lines.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle=try FileHandle(forWritingTo:lines);defer { try? handle.close() }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        for event in try allEvents() { try handle.write(contentsOf:encoder.encode(event));try handle.write(contentsOf:Data([10])) }
        try handle.synchronize()
        var entries=[StudyZIP.Entry(name:"records.json",data:try exportRecords()),
                     StudyZIP.Entry(name:"manifest.json",data:try encoder.encode(history)),
                     StudyZIP.Entry(name:"events.jsonl",file:lines)]
        for ref in history.volumes {
            let file=volumesURL.appendingPathComponent(ref.filename)
            guard try sha256(Data(contentsOf:file,options:.mappedIfSafe))==ref.sha256 else { throw StudyError.persistence("历史卷校验失败，未导出不完整档案。") }
            entries.append(StudyZIP.Entry(name:"volumes/\(ref.filename)",file:file))
        }
        try StudyZIP.write(entries,to:output);return output
    }
    private func timePoint() -> StudyTimePoint {
        activityClock.stamp(wallMs:Int64(Date().timeIntervalSince1970*1000),
                            uptimeMs:ProcessInfo.processInfo.systemUptime*1000,
                            utcOffsetSeconds:TimeZone.current.secondsFromGMT())
    }
    private func resetActivityClock(after logCount:UInt32? = nil) {
        let last=timing?.latestPoint
        activityClock=StudyActivityClock(foregroundMs:last?.foregroundMs ?? 0,clockEpoch:last?.clockEpoch ?? 0)
        let point=timePoint()
        let sequence=logCount ?? max(timing?.events.last?.sequence ?? 0,timing?.boundaries.last?.afterSequence ?? ((timing?.firstSequence ?? 1)-1))
        timing?.boundary(after:sequence,
                         point:point,visible:false,word:nil,answerVisible:false,reason:"launch-or-recovery; unsaved prior tail unknown")
    }
    func setStudyScreenVisible(_ visible: Bool) {
        studyScreenVisible=visible
        refreshActivity(reason:visible ? "study-visible":"study-hidden")
    }
    private func refreshActivity(reason: String) {
        let running=studyScreenVisible && sessionStarted && canLearn && info.has_task != 0
        guard activityClock.running != running else { return }
        let point=timePoint()
        let previouslyRunning=activityClock.running
        activityClock.running=running
        guard let coordinator,timing != nil,!fatalStorageError else { return }
        timing?.boundary(after:info.log_records,point:point,visible:running,
                         word:info.has_task != 0 ? info.word:nil,
                         answerVisible:(previouslyRunning || running) && info.revealed != 0,reason:reason)
        do { try persist(try JSONEncoder().encode(coordinator.state)) }
        catch {
            // A failed timing-only save must not silently replace the study state.
            do { try restoreDurableState() } catch { }
            fatalStorageError=true;self.error="时间记录保存需要核对，请重新打开应用。原学习档案已保留。"
        }
    }

    static func studyDay(_ date: Date) throws -> UInt32 {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let local = localCalendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: local) else { throw StudyError.engine("无法解析学习日期。") }
        let day = Int(midnight.timeIntervalSince1970 / 86400)
        guard (18_000...50_000).contains(day) else { throw StudyError.engine("日期超出可用范围，请检查系统时间。") }
        return UInt32(day)
    }
}
