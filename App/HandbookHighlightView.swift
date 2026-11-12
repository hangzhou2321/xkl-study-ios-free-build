import SwiftUI
import UIKit

struct HandbookHighlightContext {
    let cardID: String
    let state: HandbookHighlightState
    var sourceRedSpans: [HandbookHighlightSpan] = []
    var sourceYellowSpans: [HandbookHighlightSpan] = []

    func text(_ source: String, fieldID: String, visible: NSRange? = nil) -> Text {
        let displayed = handbookDisplayText(source)
        return state.runs(cardID: cardID, fieldID: fieldID, text: displayed, visible: visible,
                          sourceSpans: sourceRedSpans, sourceYellowSpans: sourceYellowSpans)
            .reduce(Text("")) { result, run in
                var fragment = AttributedString(run.text)
                if run.red { fragment.foregroundColor = .red }
                if run.yellow { fragment.backgroundColor = Color(red: 1, green: 0.93, blue: 0.20) }
                return result + Text(fragment)
            }
    }

    /// Apply a saved mark to a visible cue only when the cue uniquely matches
    /// its full field; no hidden suffix is rendered or exposed to accessibility.
    func excerpt(_ source: String, fieldID: String, prefix: String) -> Text {
        let full = handbookDisplayText(source) as NSString, visible = handbookDisplayText(prefix)
        guard !visible.isEmpty else { return Text("") }
        let first = full.range(of: visible)
        guard first.location != NSNotFound else { return Text(verbatim: visible) }
        let after = first.location + first.length
        if after < full.length, full.range(of: visible, options: [], range: NSRange(location: after, length: full.length - after)).location != NSNotFound {
            return Text(verbatim: visible)
        }
        return text(source, fieldID: fieldID, visible: first)
    }
}

private struct HandbookHighlightContextKey: EnvironmentKey {
    static let defaultValue: HandbookHighlightContext? = nil
}
extension EnvironmentValues {
    var handbookHighlightContext: HandbookHighlightContext? {
        get { self[HandbookHighlightContextKey.self] }
        set { self[HandbookHighlightContextKey.self] = newValue }
    }
}

struct HandbookMarkedText: View {
    @Environment(\.handbookHighlightContext) private var context
    let source: String
    let fieldID: String
    var prefix = ""
    var suffix = ""
    init(source: String, fieldID: String, prefix: String = "", suffix: String = "") {
        self.source = source; self.fieldID = fieldID; self.prefix = prefix; self.suffix = suffix
    }
    var body: some View {
        Text(verbatim: prefix) + (context?.text(source, fieldID: fieldID) ?? Text(verbatim: handbookDisplayText(source))) + Text(verbatim: suffix)
    }
}

struct HandbookMarkedExcerpt: View {
    @Environment(\.handbookHighlightContext) private var context
    let source: String
    let fieldID: String
    let prefix: String
    init(source: String, fieldID: String, prefix: String) {
        self.source = source; self.fieldID = fieldID; self.prefix = prefix
    }
    var body: some View {
        context?.excerpt(source, fieldID: fieldID, prefix: prefix) ?? Text(verbatim: handbookDisplayText(prefix))
    }
}

struct HandbookHighlightTarget: Identifiable {
    let card: HandbookCard
    let guide: HandbookCardPackage.MemoryGuide?
    var id: String { card.id }
}

/// Opened only after the answer is visible, or from a fully revealed directory
/// preview. It selects text without changing card text or creating a review.
struct HandbookHighlightEditor: View {
    let target: HandbookHighlightTarget
    @ObservedObject var store: HandbookHighlightStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = NSRange(location: NSNotFound, length: 0)
    #if DEBUG
    @Environment(\.handbookCardPreview) private var preview
    #endif
    private var document: HandbookHighlightDocument { .init(card: target.card, guide: target.guide) }
    init(target: HandbookHighlightTarget, store: HandbookHighlightStore) {
        self.target = target; self.store = store
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("长按并选中文字，在菜单中点“标红”或“取消标红”。")
                    .font(.footnote).foregroundStyle(.secondary)
                HandbookSelectableHighlightText(document: document, state: store.state, selected: $selected) { range, remove in
                    store.apply(document: document, selection: range, remove: remove)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("handbook-highlight-selectable")
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button("标红选中") { store.apply(document: document, selection: selected, remove: false) }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Button("取消标红") { store.apply(document: document, selection: selected, remove: true) }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }.disabled(store.blocked || selected.length == 0 || selected.location == NSNotFound)
            }.padding(16).background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("标红本卡").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                #if DEBUG
                .onAppear { preview.didRenderHighlightEditor() }
                #endif
        }
    }
}

private struct HandbookSelectableHighlightText: UIViewRepresentable {
    let document: HandbookHighlightDocument
    let state: HandbookHighlightState
    @Binding var selected: NSRange
    let apply: (NSRange, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.backgroundColor = .clear; view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let attributed = NSMutableAttributedString(string: document.text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ])
        for field in document.fields {
            var offset = field.range.location
            for run in state.runs(cardID: document.cardID, fieldID: field.id, text: field.text) {
                let length = (run.text as NSString).length
                if run.red && length > 0 { attributed.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(location: offset, length: length)) }
                offset += length
            }
        }
        if let current = view.attributedText, current.isEqual(to: attributed) { return }
        let old = view.selectedRange
        view.attributedText = attributed
        if old.location != NSNotFound, old.location <= attributed.length, old.length <= attributed.length - old.location {
            view.selectedRange = old
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HandbookSelectableHighlightText
        init(_ parent: HandbookSelectableHighlightText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            DispatchQueue.main.async { [weak self] in self?.parent.selected = range }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let red = UIAction(title: "标红", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.parent.apply(range, false) }
            let clear = UIAction(title: "取消标红", image: UIImage(systemName: "eraser")) { [weak self] _ in self?.parent.apply(range, true) }
            return UIMenu(children: [red, clear] + suggestedActions)
        }
    }
}
