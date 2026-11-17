import ActivityKit
import SwiftUI
import WidgetKit

@main
struct StudyPaceWidgets: WidgetBundle {
    var body: some Widget { StudyPaceWidget() }
}

struct StudyPaceWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyPaceActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ripple(context).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.subject).font(.headline)
                    Text(context.isStale ? "本轮已封盘" : "本轮 \(context.state.completed)/\(context.state.target)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                countdown(context).font(.title3.weight(.semibold))
            }
            .padding(16)
            .widgetURL(context.attributes.returnURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.subject, systemImage: icon(context)).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.isStale ? "已封盘" : "整点封盘").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(context.state.completed)/\(context.state.target)").monospacedDigit()
                    }
                    .font(.footnote)
                }
            } compactLeading: {
                ripple(context)
            } compactTrailing: {
                countdown(context).frame(width: 42)
            } minimal: {
                ripple(context)
            }
            .widgetURL(context.attributes.returnURL)
            .keylineTint(.teal)
        }
    }

    private func icon(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> String {
        if context.isStale { return "clock.badge.checkmark" }
        return context.state.away ? "dot.radiowaves.left.and.right" : "waveform"
    }

    private func ripple(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> some View {
        Image(systemName: icon(context))
            .foregroundStyle(.teal)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(context.isStale ? "本轮已封盘" : "背词配速")
    }

    @ViewBuilder private func countdown(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> some View {
        if context.isStale {
            Text("封盘")
        } else {
            Text(timerInterval: context.attributes.start...context.attributes.end, countsDown: true, showsHours: false)
                .contentTransition(.numericText(countsDown: true))
        }
    }
}
