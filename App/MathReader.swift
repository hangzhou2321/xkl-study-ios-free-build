import SwiftUI

/// A literal-text reader: it never parses, splits, or rewrites mathematical notation.
struct MathReader<VisualContent: View>: View {
    let question: MathQuestion
    let revealed: Bool
    @Binding var fontSize: Double
    @ViewBuilder let visual: (MathVisual) -> VisualContent
    @State private var questionImagesExpanded = false
    @State private var answerImagesExpanded = false

    private var hasText: Bool { !(question.questionText ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var needsDiagram: Bool {
        let text=[question.questionText,question.solutionNote,question.answerText].compactMap { $0 }.joined(separator:"\n")
        return ["如图", "下图", "图中", "图示", "右图", "左图", "附图", "上图"].contains { text.contains($0) }
    }
    private var size: Double { min(34,max(20,fontSize)) }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            HStack {
                Text(verbatim:question.prompt).font(.headline)
                Spacer()
                Button("A−") { fontSize=max(20,size-2) }.disabled(size <= 20).accessibilityLabel("减小数学字号")
                Text("\(Int(size))").font(.caption).monospacedDigit()
                Button("A+") { fontSize=min(34,size+2) }.disabled(size >= 34).accessibilityLabel("增大数学字号")
            }.buttonStyle(.bordered)
            if hasText {
                literal(question.questionText!)
                if needsDiagram {
                    Label("本题或解析涉及图示，请展开原题图核对。",systemImage:"photo").font(.body).foregroundStyle(.secondary)
                }
                if !question.questionVisuals.isEmpty {
                    DisclosureGroup("查看原题图",isExpanded:$questionImagesExpanded) { questionImages }
                }
            } else {
                Text("本题暂无文字，请阅读原题图。").font(.body).foregroundStyle(.secondary)
                questionImages
            }
            if revealed {
                Divider()
                Text("答案与步骤").font(.headline)
                if let answer=question.answerText, !answer.isEmpty { literal(answer) }
                if let note=question.solutionNote, !note.isEmpty { literal(note) }
                if !question.answerVisuals.isEmpty {
                    if (question.answerText ?? "").isEmpty && (question.solutionNote ?? "").isEmpty {
                        answerImages
                    } else {
                        DisclosureGroup("查看原解析图",isExpanded:$answerImagesExpanded) { answerImages }
                    }
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func literal(_ text: String) -> some View {
        Text(verbatim:text).font(.system(size:size)).lineSpacing(10)
            .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            .textSelection(.enabled)
    }
    private var questionImages: some View {
        ForEach(Array(question.questionVisuals.enumerated()),id:\.offset) { _, item in visual(item) }
    }
    private var answerImages: some View {
        ForEach(Array(question.answerVisuals.enumerated()),id:\.offset) { _, item in visual(item) }
    }
}

struct MathReaderControls: View {
    let revealed: Bool
    let reveal: () -> Void
    let grade: (Bool) -> Void
    var body: some View {
        VStack(spacing:8) {
            if revealed {
                HStack(spacing:16) {
                    Button("没记住") { grade(false) }.buttonStyle(.bordered)
                    Button("记住了") { grade(true) }.buttonStyle(.borderedProminent)
                }
                Text("独立完成且关键步骤正确，才选“记住了”。").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("翻解析",action:reveal).buttonStyle(.borderedProminent)
                Text("先在纸上独立完成，再翻解析。").font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity).padding(12).background(.regularMaterial)
    }
}

#if DEBUG
/// Only synthetic examples. This screen constructs no store and emits no learning events.
struct MathReaderPreview: View {
    @State private var fontSize: Double
    private let selectedCase: String
    init() {
        let args=ProcessInfo.processInfo.arguments
        func value(_ key:String) -> String? {
            guard let index=args.firstIndex(of:key), index+1 < args.count else { return nil }
            return args[index+1]
        }
        selectedCase=value("--math-reader-case") ?? "expressions"
        _fontSize=State(initialValue:min(34,max(20,Double(value("--math-reader-font") ?? "26") ?? 26)))
    }
    private var question: MathQuestion {
        let text: String
        switch selectedCase {
        case "matrix": text="设矩阵 M = [[2, 1], [0, 3]]，求 M^2。\n请保留计算过程中的每一行。"
        case "piecewise": text="定义 g(t) = { t^2，当 t ≥ 0；−t，当 t < 0 }。\n求 g(−3) 与 g(2)。"
        case "options": text="选择能完整描述函数性质的一项。\nA. 对任意实数 t，函数 h(t) = t^2 + 2t + 4 的值均大于零。\nB. 当 t 增大时，h(t) 在整个实数范围内严格递增。\nC. h(t) 的最小值为 4。\nD. h(t) 具有两个不同的实数零点。"
        case "diagram": text="如图，三角形的两条直角边分别为 3 与 4。求斜边长。"
        case "fallback": text=""
        default: text="设 a_n = (n^2 + 1)/(n + 2)，计算 a_2。\n再比较 √(9 + 16) 与 |−7| 的大小。\n保留原始符号：x_{k+1} = x_k + Δt·v_k。"
        }
        let imageCases=["diagram","fallback"].contains(selectedCase)
        return MathQuestion(id:"synthetic-reader-demo",type:"demo",syllabusIDs:[],prompt:"文字阅读示例",questionText:text,questionVisuals:imageCases ? [MathVisual(assetID:"synthetic-diagram",normalizedCrop:[0,0,1,1])] : [],answerVisuals:[],answerText:"示例答案：a_2 = 5/4。\n先代入 n = 2，再逐步计算分子与分母。",solutionNote:"这是纯合成的展示内容，不计入学习记录。",sourceRefs:[],duplicateAliases:[],sourceKind:"demo",reviewStatus:"demo")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                MathReader(question:question,revealed:selectedCase == "answer",fontSize:$fontSize) { _ in
                    VStack {
                        Image(systemName:"triangle").font(.system(size:100))
                        Text("合成示意图：直角边 3、4").font(.body)
                    }.frame(maxWidth:.infinity).padding()
                }.padding(20).frame(maxWidth:760)
            }.navigationTitle("数学阅读预览")
                .onAppear { print("MATH_READER_PREVIEW_READY case=\(selectedCase) font=\(Int(fontSize))") }
                .safeAreaInset(edge:.bottom,spacing:0) {
                    MathReaderControls(revealed:selectedCase == "answer",reveal:{},grade:{ _ in }).disabled(true)
                }
        }
    }
}
#endif
