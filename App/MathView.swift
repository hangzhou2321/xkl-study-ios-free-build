import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO

private struct MathZoom: Identifiable { let id=UUID(); let image: UIImage }

struct MathView: View {
    @ObservedObject var store: MathStore
    @State private var importing=false
    @State private var mode="unseen"
    @State private var source="all"
    @State private var syllabus=0
    @State private var zoom: MathZoom?
    @State private var exportURL: URL?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if let engine=store.engine {
                        if let q=engine.currentQuestion, let p=engine.presentation {
                            Text(q.prompt).font(.title2.bold())
                            Text("先在纸上独立完成，再翻解析。原题以题图为准。").foregroundStyle(.secondary)
                            if let text=q.questionText, !text.isEmpty { Text(text).font(.body).textSelection(.enabled) }
                            ForEach(Array(q.questionVisuals.enumerated()),id:\.offset) { _,visual in visualView(visual,content:engine.archive.content) }
                            if p.revealed {
                                Divider(); Text("解析与答案").font(.headline)
                                ForEach(Array(q.answerVisuals.enumerated()),id:\.offset) { _,visual in visualView(visual,content:engine.archive.content) }
                                if let answer=q.answerText { Text(answer).textSelection(.enabled) }
                                if let note=q.solutionNote { Text(note).foregroundStyle(.secondary).textSelection(.enabled) }
                                HStack { Button("没记住") { store.grade(false,presentationID:p.id) }.buttonStyle(.bordered)
                                    Button("记住了") { store.grade(true,presentationID:p.id) }.buttonStyle(.borderedProminent) }
                                Text("记住了：刚才独立完成且关键步骤正确；看懂解析不能替代独立完成。").font(.footnote)
                            } else { Button("翻解析") { store.reveal() }.buttonStyle(.borderedProminent) }
                            Text(q.sourceRefs.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary)
                            Button("回到课程") { store.leave() }
                        } else {
                            Text(engine.archive.content.title).font(.title2.bold())
                            Picker("任务",selection:$mode) { Text("快速过新题").tag("unseen"); Text("到期复习").tag("due"); Text("短期补练").tag("retry"); Text("错题").tag("wrong") }
                            Picker("来源",selection:$source) { Text("全部").tag("all"); Text("基础").tag("foundation"); Text("强化").tag("reinforcement") }
                            Picker("考纲",selection:$syllabus) { Text("全部考纲").tag(0); ForEach(engine.archive.content.syllabus) { Text("\($0.id) \($0.title)").tag($0.id) } }
                            Button("开始（\(store.questions().count)题可选）") { syncFilters(); store.start() }.buttonStyle(.borderedProminent).disabled(store.blocked)
                            Text("真实复习日由每天第一次评分的FSRS决定。首次没记住后至少10分钟可选补练；同日反复评分不会推迟真实复习日。无需完成固定轮次。").font(.footnote).foregroundStyle(.secondary)
                            DisclosureGroup("待核题（\(engine.archive.content.questions.filter { !$0.eligible }.count)）") {
                                ForEach(engine.archive.content.questions.filter { !$0.eligible }) { q in
                                    VStack(alignment:.leading) { Text(q.prompt); Text(q.reviewStatus).font(.caption)
                                        ForEach(Array(q.questionVisuals.enumerated()),id:\.offset) { _,v in visualView(v,content:engine.archive.content) }
                                        if let note=q.solutionNote { Text(note).font(.footnote) }
                                    }
                                }
                            }
                            let a=engine.score(allRatings:false), b=engine.score(allRatings:true)
                            Text("双模型同一清洁评价集：\(a.count)次。每日首次 Brier：\(a.brier.map { String(format:"%.4f",$0) } ?? "暂无")；全部评分：\(b.brier.map { String(format:"%.4f",$0) } ?? "暂无")。仅比较预测，不能据此声称记忆提升。跨App看答案无法观测。").font(.caption).foregroundStyle(.secondary)
                            Button("导出数学记录") { do { exportURL=try store.export() } catch { store.error=error.localizedDescription } }
                            if let exportURL { ShareLink("分享数学记录文件",item:exportURL) }
                        }
                    } else { Text("导入数学课程").font(.title2); Text("选择离线 .xklmath 文件，题图和解析都保存在本机。") }
                    Button("导入数学包") { importing=true }.disabled(store.blocked)
                }.padding(20).frame(maxWidth:760)
            }.navigationTitle("数学")
            .onAppear { store.processInbox(); syncFilters() }.onChange(of:mode) { _,_ in syncFilters() }.onChange(of:source) { _,_ in syncFilters() }.onChange(of:syllabus) { _,_ in syncFilters() }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data,.json]) { result in
                switch result { case .success(let url):store.importContent(from:url); case .failure(let error):store.error=error.localizedDescription }
            }
            .alert("数学记录",isPresented:Binding(get:{ store.error != nil },set:{ if !$0 { store.error=nil } })) { Button("知道了",role:.cancel) { store.error=nil } } message: { Text(store.error ?? "") }
            .sheet(item:$zoom) { item in
                NavigationStack { ScrollView([.horizontal,.vertical]) { Image(uiImage:item.image).resizable().scaledToFit().frame(width:1400) }.navigationTitle("题图放大").toolbar { Button("关闭") { zoom=nil } } }
            }
        }
    }
    private func syncFilters() { store.mode=mode; store.source=source == "all" ? nil:source; store.syllabus=syllabus == 0 ? nil:syllabus; store.objectWillChange.send() }
    @ViewBuilder private func visualView(_ visual: MathVisual, content: MathContent) -> some View {
        if let asset=content.assets.first(where:{ $0.id == visual.assetID }),let data=Data(base64Encoded:asset.dataBase64),let source=CGImageSourceCreateWithData(data as CFData,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceShouldCacheImmediately:false] as CFDictionary) {
            let c=visual.normalizedCrop
            let rect=CGRect(x:c[0]*Double(cg.width),y:c[1]*Double(cg.height),width:c[2]*Double(cg.width),height:c[3]*Double(cg.height))
            if let crop=cg.cropping(to:rect) {
                Image(uiImage:UIImage(cgImage:crop)).resizable().scaledToFit().accessibilityLabel("数学题图")
                Button("放大当前裁剪图") { zoom=MathZoom(image:UIImage(cgImage:crop)) }
            }
        }
    }
}
