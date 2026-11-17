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
                    if context.attributes.lookupID != nil {
                        Text(lookupStatus(context)).font(.subheadline)
                    } else {
                        Text(context.isStale ? "本轮已封盘" : "本轮 \(context.state.completed)/\(context.state.target)")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                countdown(context, expanded: true).font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .widgetURL(context.attributes.returnURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.subject, systemImage: icon(context)).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context, expanded: true).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.attributes.lookupID != nil {
                        Text(lookupStatus(context)).font(.footnote)
                    } else {
                        HStack(spacing: 8) {
                            Text(context.isStale ? "已封盘" : "整点封盘").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(context.state.completed)/\(context.state.target)").monospacedDigit()
                        }
                        .font(.footnote)
                    }
                }
            } compactLeading: {
                if context.attributes.lookupID != nil && context.state.target > 0 {
                    HStack(spacing: 3) {
                        ripple(context)
                        Text("\(context.state.completed)/\(context.state.target)").font(.caption2.monospacedDigit())
                    }
                } else { ripple(context) }
            } compactTrailing: {
                countdown(context, expanded: false).frame(width: 45, alignment: .trailing)
            } minimal: {
                ripple(context)
            }
            .widgetURL(context.attributes.returnURL)
            .keylineTint(context.attributes.lookupID != nil ? .red : .teal)
        }
    }

    private func lookupStatus(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> String {
        if context.isStale { return "点一下回原卡，写一句复述" }
        return context.state.target > 0
            ? "正在为第 \(context.state.completed)/\(context.state.target) 张卡查资料"
            : "正在查这张卡"
    }

    private func icon(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> String {
        if context.attributes.lookupID != nil {
            return context.isStale ? "arrow.uturn.backward.circle" : "dot.radiowaves.left.and.right"
        }
        if context.isStale { return "clock.badge.checkmark" }
        return context.state.away ? "dot.radiowaves.left.and.right" : "waveform"
    }

    private func ripple(_ context: ActivityViewContext<StudyPaceActivityAttributes>) -> some View {
        Image(systemName: icon(context))
            .foregroundStyle(context.attributes.lookupID != nil ? Color.red : Color.teal)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(context.attributes.lookupID != nil ? lookupStatus(context) : "背词配速")
    }

    @ViewBuilder private func countdown(_ context: ActivityViewContext<StudyPaceActivityAttributes>, expanded: Bool) -> some View {
        let lookup = context.attributes.lookupID != nil
        let tint = lookup ? Color.red : Color.primary
        if context.isStale {
            Text(lookup ? "已超时" : "封盘").foregroundStyle(tint)
        } else if lookup, expanded, #available(iOS 18.0, *) {
            HStack(spacing: 3) {
                Text(.currentDate, format: .offset(to: context.attributes.end,
                                                    allowedFields: [.second], maxFieldCount: 1, sign: .never))
                    .contentTransition(.numericText(countsDown: true))
                Text("后超时")
            }
            .foregroundStyle(tint)
            .monospacedDigit()
        } else {
            Text(timerInterval: context.attributes.start...context.attributes.end, countsDown: true, showsHours: false)
                .contentTransition(.numericText(countsDown: true))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }
}
