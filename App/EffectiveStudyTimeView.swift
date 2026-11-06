import SwiftUI

/// This is a separate, forward-only timer. It never changes the word or course engines.
struct EffectiveStudyTimeSummary: View {
    @ObservedObject var store: EffectiveStudyTimeStore
    var allowDateSelection = false
    @State private var selectedDate = Date()

    private var day: Date { allowDateSelection ? selectedDate : Date() }
    private var dayTotal: TimeInterval {
        EffectiveStudyArea.allCases.reduce(0) { $0 + store.seconds(for: $1, on: day) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("有效学习时间").font(.headline)
                Spacer()
                if store.isCounting { Label("计时中", systemImage: "circle.fill").font(.caption).foregroundStyle(.green) }
            }
            if allowDateSelection {
                DatePicker("查询日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
            LabeledContent(allowDateSelection ? "所选日期" : "今天", value: duration(dayTotal))
            ForEach(EffectiveStudyArea.allCases, id: \.rawValue) { area in
                HStack(alignment: .firstTextBaseline) {
                    Text(area.title)
                    Spacer()
                    Text("\(duration(store.seconds(for: area, on: day))) · 累计 \(duration(store.totalSeconds(for: area)))")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }.font(.subheadline)
            }
            Text("只统计前台学习内容；连续 1 分钟未操作后暂停，再操作继续。记录从本版开始，旧时间不补算。")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        let hours = value / 3600, minutes = (value % 3600) / 60, remainder = value % 60
        if hours > 0 { return "\(hours)小时\(String(format: "%02d", minutes))分" }
        if minutes > 0 { return "\(minutes)分\(String(format: "%02d", remainder))秒" }
        return "\(remainder)秒"
    }
}
