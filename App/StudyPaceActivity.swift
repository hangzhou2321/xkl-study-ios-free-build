import ActivityKit
import Foundation

@MainActor
final class StudyPaceActivity {
    private var attemptedStart: Date?
    private var pending: Task<Void, Never>?
    private var sent: ActivityContent<StudyPaceActivityAttributes.ContentState>?
    private var current: Activity<StudyPaceActivityAttributes>?

    func sync(slot: HourlyStudyPlan.Slot?, subject: String?, away: Bool, now: Date = .now) {
        typealias Live = Activity<StudyPaceActivityAttributes>
        guard let slot, let subject, now < slot.end else {
            let expired = Live.activities
            current = nil
            sent = nil
            enqueue { for activity in expired { await activity.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let state = StudyPaceActivityAttributes.ContentState(completed: slot.credited, target: slot.target, away: away)
        let content = ActivityContent(state: state, staleDate: slot.end, relevanceScore: 1)
        if current?.attributes.start != slot.start {
            sent = nil
            let existing = Live.activities
            current = existing.first { $0.attributes.start == slot.start }
            let old = existing.filter { $0.attributes.start != slot.start }
            if !old.isEmpty {
                enqueue { for activity in old { await activity.end(nil, dismissalPolicy: .immediate) } }
            }
        }
        if let current {
            guard sent?.state != state else { return }
            sent = content
            enqueue { await current.update(content) }
        } else if !away, attemptedStart != slot.start, ActivityAuthorizationInfo().areActivitiesEnabled {
            attemptedStart = slot.start
            current = try? Live.request(attributes: .init(start: slot.start, end: slot.end, subject: subject),
                                        content: content, pushType: nil)
            sent = current == nil ? nil : content
        }
    }

    private func enqueue(_ action: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await action()
        }
    }
}
