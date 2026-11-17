import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class CardLookupCoordinator: ObservableObject {
    private let file: URL
    private let notifications: UNUserNotificationCenter
    @Published private(set) var session: CardLookupSession?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = base.appendingPathComponent("CardLookup/pending.json")
        notifications = .current()
        if let data = try? Data(contentsOf: file) {
            session = try? JSONDecoder().decode(CardLookupSession.self, from: data)
        }
    }

    func start(_ next: CardLookupSession, prompt: String) throws {
        try persist(next)
        if let old = session { cancelReminder(old) }
        session = next
        UIPasteboard.general.setItems([[UTType.plainText.identifier: prompt]],
                                      options: [.localOnly: true, .expirationDate: next.deadline.addingTimeInterval(300)])
    }

    func scheduleReminder(for started: CardLookupSession) {
        Task {
            do {
                let settings = await notifications.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    guard try await notifications.requestAuthorization(options: [.alert, .sound]) else { return }
                } else {
                    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                            || settings.authorizationStatus == .ephemeral else { return }
                }
                let timeLeft = started.deadline.timeIntervalSinceNow
                guard timeLeft > 0, session?.id == started.id, session?.returnedAt == nil else { return }
                let content = UNMutableNotificationContent()
                content.title = "查卡时间到"
                content.body = "点这里回到刚才的卡，写一句你现在能说出来的话。"
                content.sound = .default
                content.userInfo = ["cardLookupID": started.id.uuidString]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeLeft, repeats: false)
                try await notifications.add(UNNotificationRequest(identifier: started.notificationID, content: content, trigger: trigger))
                if session?.id != started.id || session?.returnedAt != nil { cancelReminder(started) }
            } catch {
                // The user's notification settings or the system may prevent delivery.
            }
        }
    }

    func didEnterBackground() {
        guard var next = session, next.noteDeparture() else { return }
        session = next
        try? persist(next)
    }

    func returnToCard(id: UUID, now: Date = .now) -> CardLookupSession? {
        guard var next = session, next.id == id else { return nil }
        if next.noteReturn(at: now) {
            session = next
            try? persist(next)
        }
        cancelReminder(next)
        return next
    }

    func finish(id: UUID) {
        guard let session, session.id == id else { return }
        cancelReminder(session)
        self.session = nil
        try? FileManager.default.removeItem(at: file)
    }

    private func persist(_ next: CardLookupSession) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
    }

    private func cancelReminder(_ target: CardLookupSession) {
        notifications.removePendingNotificationRequests(withIdentifiers: [target.notificationID])
        notifications.removeDeliveredNotifications(withIdentifiers: [target.notificationID])
    }
}

@MainActor
final class StudyAppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let openedLookup = Notification.Name("CardLookupNotificationOpened")
    private(set) static var pendingLookup: UUID?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["cardLookupID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            Self.pendingLookup = id
            NotificationCenter.default.post(name: Self.openedLookup, object: id)
        }
    }

    static func takePendingLookup() -> UUID? {
        defer { pendingLookup = nil }
        return pendingLookup
    }
}

struct CardLookupRecap: Identifiable {
    let session: CardLookupSession
    let title: String
    let question: String
    var id: UUID { session.id }
}

struct CardLookupRecapView: View {
    let card: CardLookupRecap
    let submit: (String) -> Bool
    let cancel: () -> Void
    @State private var recap = ""
    @State private var error = false
    @FocusState private var editing: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 64.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if card.session.timedOut {
                        Label("已到 90 秒，继续复述", systemImage: "clock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(card.title).font(.headline)
                    Text(card.question).font(.subheadline).foregroundStyle(.secondary)
                    TextField("用自己的话说这张卡的关键", text: $recap, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($editing)
                        .padding(12)
                        .frame(minHeight: fieldHeight, alignment: .topLeading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("card-lookup-recap")
                    Button {
                        if !submit(recap) { error = true }
                    } label: {
                        Text("确认并算过").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!CardLookupSession.validRecap(recap))
                    if error {
                        Text("这次自评没有保存。请确认原卡仍在当前队列，再重试。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("一句话复述")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回原卡", action: cancel) }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .task { editing = true }
    }
}
