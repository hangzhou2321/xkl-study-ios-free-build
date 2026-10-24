import Foundation
import SwiftUI

/// Local vector geometry and native labels. Viewing or enlarging a diagram
/// never changes a lesson position, answer, or review schedule.
struct ConceptDiagramView: View {
    let diagram: ConceptDiagram
    @State private var enlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(diagram.title).font(.headline)
            ScrollView(.horizontal) {
                ConceptDiagramBoard(diagram: diagram, displayWidth: 320)
            }
            .frame(height: CGFloat(diagram.height))
            .accessibilityHint("可打开大图查看，也可展开下面的文字说明。")

            Button("放大看图", systemImage: "arrow.up.left.and.arrow.down.right") {
                enlarged = true
            }
            .buttonStyle(.bordered)

            DisclosureGroup("图的文字说明") {
                Text(diagram.description)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.subheadline)
        }
        .sheet(isPresented: $enlarged) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("左右滑动看完整张图；文字和图形一起放大。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            ConceptDiagramBoard(diagram: diagram, displayWidth: 640)
                        }
                        .frame(height: CGFloat(diagram.height) * 2)
                        Text(diagram.description)
                            .font(.body).textSelection(.enabled)
                    }
                    .padding()
                }
                .navigationTitle(diagram.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { enlarged = false }
                    }
                }
            }
        }
    }
}

private struct ConceptDiagramBoard: View {
    let diagram: ConceptDiagram
    let displayWidth: CGFloat
    private var scale: CGFloat { displayWidth / CGFloat(diagram.width) }
    private var boardHeight: CGFloat { CGFloat(diagram.height) * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Canvas { context, _ in
                for item in diagram.shapes {
                    let rect = CGRect(x: CGFloat(item.x) * scale, y: CGFloat(item.y) * scale,
                                      width: CGFloat(item.width) * scale, height: CGFloat(item.height) * scale)
                    let path: Path
                    switch item.kind {
                    case "ellipse": path = Ellipse().path(in: rect)
                    case "roundedRect": path = RoundedRectangle(cornerRadius: 8 * scale).path(in: rect)
                    default: path = Rectangle().path(in: rect)
                    }
                    if item.fill != "none" { context.fill(path, with: .color(color(item.fill))) }
                    if item.stroke != "none" {
                        context.stroke(path, with: .color(color(item.stroke)), lineWidth: 1.5 * scale)
                    }
                }
                for item in diagram.paths {
                    guard let first = item.points.first else { continue }
                    var path = Path()
                    path.move(to: point(first))
                    for next in item.points.dropFirst() { path.addLine(to: point(next)) }
                    context.stroke(path, with: .color(color(item.color)),
                                   style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round,
                                                      lineJoin: .round, dash: item.dashed ? [5 * scale, 4 * scale] : []))
                    if item.arrow, item.points.count >= 2 {
                        let end = point(item.points[item.points.count - 1])
                        let before = point(item.points[item.points.count - 2])
                        let angle = atan2(end.y - before.y, end.x - before.x)
                        let length: CGFloat = 8 * scale
                        let halfWidth: CGFloat = 4 * scale
                        let base = CGPoint(x: end.x - cos(angle) * length, y: end.y - sin(angle) * length)
                        var head = Path()
                        head.move(to: end)
                        head.addLine(to: CGPoint(x: base.x - sin(angle) * halfWidth,
                                                y: base.y + cos(angle) * halfWidth))
                        head.addLine(to: CGPoint(x: base.x + sin(angle) * halfWidth,
                                                y: base.y - cos(angle) * halfWidth))
                        head.closeSubpath()
                        context.fill(head, with: .color(color(item.color)))
                    }
                }
            }
            .accessibilityHidden(true)

            ForEach(diagram.labels.indices, id: \.self) { index in
                let label = diagram.labels[index]
                Text(label.text)
                    .font(.system(size: max(14, CGFloat(label.size)) * scale,
                                  weight: label.bold ? .semibold : .regular))
                    .foregroundStyle(color(label.color))
                    .multilineTextAlignment(textAlignment(label.align))
                    .frame(width: CGFloat(label.width) * scale, height: CGFloat(label.height) * scale,
                           alignment: alignment(label.align))
                    .position(x: (CGFloat(label.x) + CGFloat(label.width) / 2) * scale,
                              y: (CGFloat(label.y) + CGFloat(label.height) / 2) * scale)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: displayWidth, height: boardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diagram.title)
        .accessibilityValue(diagram.description)
        .accessibilityAddTraits(.isImage)
    }

    private func point(_ value: ConceptDiagram.Point) -> CGPoint {
        CGPoint(x: CGFloat(value.x) * scale, y: CGFloat(value.y) * scale)
    }
    private func alignment(_ value: String) -> Alignment {
        switch value {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }
    private func textAlignment(_ value: String) -> TextAlignment {
        switch value {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }
    /// Fixed colors deliberately stay dark on the white drawing board in both themes.
    private func color(_ name: String) -> Color {
        switch name {
        case "blue": return Color(red: 0.08, green: 0.31, blue: 0.72)
        case "green": return Color(red: 0.05, green: 0.42, blue: 0.27)
        case "orange": return Color(red: 0.65, green: 0.29, blue: 0.04)
        case "gray": return Color(red: 0.36, green: 0.40, blue: 0.45)
        case "white": return .white
        case "paleBlue": return Color(red: 0.89, green: 0.94, blue: 1.0)
        case "paleGreen": return Color(red: 0.89, green: 0.97, blue: 0.92)
        case "paleOrange": return Color(red: 1.0, green: 0.95, blue: 0.86)
        case "paleGray": return Color(red: 0.94, green: 0.95, blue: 0.96)
        case "none": return .clear
        default: return Color(red: 0.10, green: 0.14, blue: 0.19)
        }
    }
}
