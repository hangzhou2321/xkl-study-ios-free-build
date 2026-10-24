import SwiftUI
import WebKit

/// Pass only currently visible blocks. Hidden answers must never enter this view.
struct MathRichTextView: View {
    var blocks: [MathRichBlock]
    var fontSize: Double = 26
    var onFailure: ((String) -> Void)? = nil
    var onReady: ((Bool) -> Void)? = nil
    @State private var height: CGFloat = 80
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MathWebContent(blocks: blocks, fontSize: fontSize, height: $height, onReady: { value in
                if value { failure = nil }
                onReady?(value)
            }) { message in
                failure = message
                onFailure?(message)
            }
            .frame(height: height)
            if let failure {
                Text("公式排版未完成，请使用本页的原题核对入口。\n\(failure)")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

private struct MathWebContent: UIViewRepresentable {
    let blocks: [MathRichBlock]
    let fontSize: Double
    @Binding var height: CGFloat
    let onReady: (Bool) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "mathRenderer")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let folder = Bundle.main.url(forResource: "MathRenderer", withExtension: nil),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path) {
            context.coordinator.folder = folder.standardizedFileURL
            context.coordinator.navigation = web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        } else {
            DispatchQueue.main.async { onReady(false); onFailure("离线公式资源缺失") }
        }
        let coordinator = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak coordinator] in
            guard let coordinator, !coordinator.ready else { return }
            coordinator.fail("离线公式引擎未就绪")
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render()
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "mathRenderer")
        web.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathWebContent
        weak var web: WKWebView?
        var folder: URL?
        var ready = false
        var token = ""
        var signature: Data?
        var sentToken = ""
        var navigation: WKNavigation?
        var active = true
        init(_ parent: MathWebContent) { self.parent = parent }
        func render() {
            guard active, let web else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = try encoder.encode(parent.blocks)
                let signatureData = data + Data(String(parent.fontSize).utf8)
                if signatureData != signature {
                    signature = signatureData
                    token = UUID().uuidString
                    let loadingToken = token
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.active, self.token == loadingToken else { return }
                        self.parent.onReady(false)
                    }
                }
                guard ready, sentToken != token else { return }
                sentToken = token
                let payload: [String: Any] = ["token": token, "fontSize": parent.fontSize,
                                              "blocks": try JSONSerialization.jsonObject(with: data)]
                // WK argument transport never embeds author content in JavaScript source.
                let renderToken = token
                web.callAsyncJavaScript("window.renderContent(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
                    guard let self, self.active, self.token == renderToken else { return }
                    if case .failure(let error) = result { self.fail(error.localizedDescription) }
                }
            } catch { fail(error.localizedDescription) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, let payload = message.body as? [String: Any] else { return }
            if payload["ready"] as? Bool == true { ready = true; render(); return }
            guard payload["token"] as? String == token else { return }
            if let value = payload["height"] as? Double, value.isFinite {
                parent.height = CGFloat(max(40, min(100_000, value)))
            }
            if let errors = payload["errors"] as? [String], !errors.isEmpty {
                fail(errors.joined(separator: "\n"))
            } else if payload["height"] as? Double != nil {
                parent.onReady(true)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.isFileURL, let folder,
                  url.standardizedFileURL == folder.appendingPathComponent("index.html"),
                  navigationAction.navigationType != .linkActivated else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func fail(_ message: String) {
            guard active else { return }
            parent.onReady(false)
            parent.onFailure(message)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation else { return }
            ready = false
            fail(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation else { return }
            ready = false
            fail(error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; signature = nil
            fail("公式进程已中断，请重新打开本题")
        }
    }
}
