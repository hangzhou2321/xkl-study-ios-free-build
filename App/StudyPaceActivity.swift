import ActivityKit
import Foundation

@MainActor
final class StudyPaceActivity {
    private var attemptedStart: URL?
    private var pending: Task<Void, Never>?
    private var sent: StudyPaceActivityAttributes.ContentState?
    private var current: Activity<StudyPaceActivityAttributes>?

    func sync(slot: HourlyStudyPlan.Slot?, subject: String?, lookup: CardLookupSession?,
              away: Bool, now: Date = .now) {
        if let lookup {
            // Keep the expired lookup visible as a way back while iOS delivers the reminder.
            let title = EffectiveStudyArea(rawValue: lookup.subject)?.title ?? "背词"
            let attrs = StudyPaceActivityAttributes(start: lookup.startedAt, end: lookup.deadline,
                                                    subject: title, lookupID: lookup.id)
            sync(attributes: attrs, state: .init(completed: lookup.progress?.index ?? 0,
                                                 target: lookup.progress?.target ?? 0, away: away),
                 mayStart: !away && now < lookup.deadline)
        } else if let slot, let subject, now < slot.end {
            sync(attributes: .init(start: slot.start, end: slot.end, subject: subject),
                 state: .init(completed: slot.credited, target: slot.target, away: away), mayStart: !away)
        } else {
            let expired = Activity<StudyPaceActivityAttributes>.activities
            current = nil
            sent = nil
            attemptedStart = nil
            end(expired)
        }
    }

    private func sync(attributes: StudyPaceActivityAttributes, state: StudyPaceActivityAttributes.ContentState,
                      mayStart: Bool) {
        typealias Live = Activity<StudyPaceActivityAttributes>
        let key = attributes.returnURL
        let content = ActivityContent(state: state, staleDate: attributes.end,
                                      relevanceScore: attributes.lookupID == nil ? 1 : 100)
        if current?.attributes.returnURL != key {
            sent = nil
            let existing = Live.activities
            current = existing.first { $0.attributes.returnURL == key }
            end(existing.filter { $0.attributes.returnURL != key })
        }
        if let current {
            guard sent != state else { return }
            sent = state
            enqueue { await current.update(content) }
        } else if mayStart, attemptedStart != key, ActivityAuthorizationInfo().areActivitiesEnabled {
            attemptedStart = key
            current = try? Live.request(attributes: attributes, content: content, pushType: nil)
            sent = current == nil ? nil : state
        }
    }

    private func end(_ activities: [Activity<StudyPaceActivityAttributes>]) {
        guard !activities.isEmpty else { return }
        enqueue {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
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
