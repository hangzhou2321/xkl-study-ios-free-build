import Foundation

/// Bounded vector primitives only. No remote resources or executable markup.
struct ConceptDiagram: Codable, Equatable {
    let version: Int
    let title: String
    let width: Double
    let height: Double
    let description: String
    let shapes: [Shape]
    let paths: [Stroke]
    let labels: [Label]

    struct Point: Codable, Equatable { let x: Double; let y: Double }
    struct Shape: Codable, Equatable {
        let kind: String
        let x: Double; let y: Double; let width: Double; let height: Double
        let stroke: String; let fill: String
    }
    struct Stroke: Codable, Equatable {
        let points: [Point]
        let color: String
        let dashed: Bool
        let arrow: Bool
    }
    struct Label: Codable, Equatable {
        let text: String
        let x: Double; let y: Double; let width: Double; let height: Double
        let size: Double
        let color: String
        let align: String
        let bold: Bool
    }

    func validate() throws {
        func text(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
        }
        func point(_ x: Double, _ y: Double) -> Bool {
            x.isFinite && y.isFinite && x >= 0 && x <= width && y >= 0 && y <= height
        }
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
            w.isFinite && h.isFinite && w > 0 && h > 0 && point(x, y) && point(x + w, y + h)
        }
        let colors: Set<String> = ["ink", "blue", "green", "orange", "gray"]
        let fills: Set<String> = ["white", "paleBlue", "paleGreen", "paleOrange", "paleGray", "none"]
        guard version == 1, width == 320, height.isFinite, (160...420).contains(height),
              text(title, limit: 30), text(description, limit: 600),
              shapes.count <= 60, paths.count <= 80, labels.count <= 40,
              !shapes.isEmpty || !paths.isEmpty, !labels.isEmpty,
              paths.reduce(0, { $0 + $1.points.count }) <= 600 else {
            throw ExamError.invalid("图解版本、尺寸或数量无效。")
        }
        for shape in shapes {
            guard ["rect", "roundedRect", "ellipse"].contains(shape.kind),
                  rect(shape.x, shape.y, shape.width, shape.height),
                  colors.contains(shape.stroke) || shape.stroke == "none", fills.contains(shape.fill) else {
                throw ExamError.invalid("图解形状越界或样式无效。")
            }
        }
        for path in paths {
            guard (2...300).contains(path.points.count), colors.contains(path.color),
                  path.points.allSatisfy({ point($0.x, $0.y) }),
                  zip(path.points, path.points.dropFirst()).allSatisfy({ $0.0 != $0.1 }) else {
                throw ExamError.invalid("图解连线越界或样式无效。")
            }
        }
        for label in labels {
            guard text(label.text, limit: 90), rect(label.x, label.y, label.width, label.height),
                  label.size.isFinite, (14...22).contains(label.size), colors.contains(label.color),
                  ["leading", "center", "trailing"].contains(label.align) else {
                throw ExamError.invalid("图解标签越界或字号无效。")
            }
        }
    }
}
