import SwiftUI
import WebKit
import PDFKit
import UIKit

@MainActor
struct OriginalPracticeView: View {
    let subject: ConceptSubject
    var onLearningChanged: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PracticeHost(subject: subject, leave: { dismiss() }, learning: onLearningChanged)
            .id(subject.rawValue)
            .interactiveDismissDisabled(true)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

@MainActor
private struct PracticeHost: UIViewControllerRepresentable {
    let subject: ConceptSubject
    let leave: () -> Void
    let learning: (Bool) -> Void

    func makeUIViewController(context: Context) -> PracticeController {
        PracticeController(subject: subject, leave: leave, learning: learning)
    }

    func updateUIViewController(_ controller: PracticeController, context: Context) {}

    static func dismantleUIViewController(_ controller: PracticeController, coordinator: ()) {
        controller.tearDown()
    }
}

// No read access to file:// is granted to WebKit. Relative links use one private origin
// whose only backing directory is the read-only resource folder in the signed bundle.
@MainActor
private final class PracticeResources: NSObject, WKURLSchemeHandler {
    static let scheme = "study-originals"
    private let root: URL
    private let types = ["html":"text/html", "htm":"text/html", "png":"image/png",
                         "webp":"image/webp", "jpg":"image/jpeg", "jpeg":"image/jpeg",
                         "gif":"image/gif", "svg":"image/svg+xml", "pdf":"application/pdf",
                         "css":"text/css", "js":"application/javascript",
                         "woff":"font/woff", "woff2":"font/woff2"]
    private let policy = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src study-originals: data:; font-src 'self'; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    override init() {
        root = Bundle.main.bundleURL.appendingPathComponent("OriginalPractice", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        super.init()
    }

    func home(_ subject: ConceptSubject) -> URL? {
        guard subject == .mechanics || subject == .circuit else { return nil }
        var u = URLComponents()
        u.scheme = Self.scheme; u.host = "bundle"; u.path = "/course.html"
        u.queryItems = [URLQueryItem(name: "nativeSubject", value: subject.rawValue)]
        return u.url
    }

    func file(_ url: URL) -> URL? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == Self.scheme, c.host == "bundle", c.user == nil,
              c.password == nil, c.port == nil, let path = c.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 })
        else { return nil }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let f = parts.reduce(root) { $0.appendingPathComponent(String($1), isDirectory: false) }
            .standardizedFileURL.resolvingSymlinksInPath()
        guard f.path.hasPrefix(root.path + "/"), types[f.pathExtension.lowercased()] != nil,
              FileManager.default.isReadableFile(atPath: f.path) else { return nil }
        return f
    }

    func page(_ url: URL) -> URL? {
        guard let f = file(url), ["html","htm","png","jpg","jpeg","webp","gif","pdf"].contains(f.pathExtension.lowercased()) else { return nil }
        return f
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard task.request.httpMethod == nil || task.request.httpMethod == "GET",
              let u = task.request.url, let f = file(u), let mime = types[f.pathExtension.lowercased()]
        else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        do {
            var data = try Data(contentsOf: f, options: .mappedIfSafe)
            if mime == "text/html" {
                guard var html = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
                // The older index pages use HTML's implicit head.
                if let head = html.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
                    html.insert(contentsOf: csp, at: head.upperBound)
                } else if let tag = html.range(of: #"<html(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
                    html.insert(contentsOf: "<head>" + csp, at: tag.upperBound)
                } else {
                    let index = html.range(of: #"<!doctype\s+html[^>]*>"#, options: [.regularExpression, .caseInsensitive])?.upperBound ?? html.startIndex
                    html.insert(contentsOf: "<head>" + csp, at: index)
                }
                data = Data(html.utf8)
            }
            let response = URLResponse(url: u, mimeType: mime, expectedContentLength: data.count,
                                       textEncodingName: mime == "text/html" ? "utf-8" : nil)
            task.didReceive(response); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    // Each small request above completes synchronously on the main actor; PDF documents
    // are opened natively by URL and are not copied into the web content process.
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
private final class PracticeMessages: NSObject, WKScriptMessageHandler {
    weak var owner: PracticeController?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor
private final class PracticeController: UIViewController, WKNavigationDelegate, WKUIDelegate, PDFViewDelegate {
    private struct Place {
        var url: URL
        var scroll: CGPoint = .zero
        var pdfIndex: Int?
    }
    private enum Move { case next, back, home }
    private let subject: ConceptSubject
    private let leave: () -> Void
    private let learning: (Bool) -> Void
    private let resources = PracticeResources()
    private let messages = PracticeMessages()
    private let panel = UIView(), notice = UILabel()
    private let back = UIButton(type: .system), homeButton = UIButton(type: .system)
    private var web: WKWebView?
    private var pdf: PDFView?
    private var store: OriginalPracticeStorage?
    private var stack: [Place] = []
    private var position: Place?
    private var permittedLoad: URL?
    private var activeNavigation: WKNavigation?
    private var blocked = false
    private var transitioning = false
    private var learningActive = false
    private var documentReady = false
    private var cardOpen = false

    init(subject: ConceptSubject, leave: @escaping () -> Void, learning: @escaping (Bool) -> Void) {
        self.subject = subject; self.leave = leave; self.learning = learning
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(subject:leave:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let close = UIButton(type: .system)
        back.setTitle("返回", for: .normal)
        homeButton.setTitle(subject.shortTitle + "首页", for: .normal)
        close.setTitle("退出练习", for: .normal)
        back.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        homeButton.addTarget(self, action: #selector(goHome), for: .touchUpInside)
        close.addTarget(self, action: #selector(closeScreen), for: .touchUpInside)
        let tools = UIStackView(arrangedSubviews: [back,homeButton,UIView(),close])
        tools.axis = .horizontal; tools.alignment = .fill; tools.spacing = 16
        tools.isLayoutMarginsRelativeArrangement = true
        tools.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let layout = UIStackView(arrangedSubviews: [tools,panel])
        layout.axis = .vertical; layout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layout)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: safe.trailingAnchor), layout.topAnchor.constraint(equalTo: safe.topAnchor),
            layout.bottomAnchor.constraint(equalTo: safe.bottomAnchor),tools.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        notice.textAlignment = .center; notice.numberOfLines = 0; notice.textColor = .label
        notice.font = .preferredFont(forTextStyle: .body); notice.backgroundColor = .systemBackground
        notice.adjustsFontForContentSizeCategory = true
        notice.isHidden = true; install(notice)
        do {
            store = try OriginalPracticeStorage()
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.dataDetectorTypes = []
            config.setURLSchemeHandler(resources, forURLScheme: PracticeResources.scheme)
            messages.owner = self; config.userContentController.add(messages, name: "originalPracticeStore")
            config.userContentController.add(messages, name: "originalPracticeLearning")
            let w = WKWebView(frame: .zero, configuration: config)
            w.allowsLinkPreview = false; w.allowsBackForwardNavigationGestures = false
            w.navigationDelegate = self; w.uiDelegate = self
            web = w; install(w)
            guard let url = resources.home(subject) else { fail("这门课没有原题练习入口。", terminal: true); return }
            open(Place(url: url), move: .home)
        } catch { fail("无法读取原题练习记录，未开始本次练习。\n\(error.localizedDescription)", terminal: true) }
    }

    private func install(_ v: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: panel.topAnchor),v.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: panel.leadingAnchor),v.trailingAnchor.constraint(equalTo: panel.trailingAnchor)])
    }

    private func fail(_ message: String, terminal: Bool = false) {
        documentReady = false; setLearning(false)
        if terminal {
            blocked = true; permittedLoad = nil; web?.isUserInteractionEnabled = false
            web?.evaluateJavaScript("window.__originalPracticeStorageAbort?.()", completionHandler: nil)
            web?.stopLoading()
        }
        transitioning = false; notice.text = message; notice.isHidden = false; panel.bringSubviewToFront(notice)
        back.isEnabled = !blocked && !stack.isEmpty; homeButton.isEnabled = !blocked
    }

    @objc private func goBack() { if let last = stack.last { request(last, move: .back) } }
    @objc private func goHome() { if let url = resources.home(subject) { request(Place(url: url), move: .home) } }
    @objc private func closeScreen() {
        documentReady = false; setLearning(false)
        guard !blocked, let w = web, !w.isHidden, w.url != nil else { leave(); return }
        view.endEditing(true)
        w.evaluateJavaScript("void 0") { [weak self] _,_ in
            // A pending bridge write may have reported an error during this drain.
            guard let self, !self.blocked else { return }
            self.leave()
        }
    }

    private func request(_ dest: Place, move: Move) {
        guard !blocked, !transitioning else { return }
        // Drain earlier posts from an input handler before taking the next page's storage snapshot.
        transitioning = true
        if let w = web, !w.isHidden, w.url != nil {
            w.evaluateJavaScript("void 0") { [weak self] _,_ in
                guard let self, !self.blocked else { return }; self.open(dest, move: move)
            }
        } else { open(dest, move: move) }
    }

    private func open(_ dest: Place, move: Move) {
        guard !blocked, let w = web, let s = store else { return }
        documentReady = false; cardOpen = false; setLearning(false)
        guard let f = resources.page(dest.url) else { fail("找不到这份练习资料，请返回科目首页。"); return }
        if move == .next, var current = position {
            if let pdf, let doc = pdf.document, let page = pdf.currentPage { current.pdfIndex = doc.index(for: page) }
            else { current.scroll = w.scrollView.contentOffset }
            stack.append(current)
        } else if move == .back { _ = stack.popLast() }
        else if move == .home { stack.removeAll() }
        position = dest; transitioning = false; back.isEnabled = !stack.isEmpty
        notice.isHidden = true; homeButton.isEnabled = true
        pdf?.removeFromSuperview(); pdf = nil; permittedLoad = nil; activeNavigation = nil; w.stopLoading()
        if f.pathExtension.lowercased() == "pdf" {
            w.isHidden = true
            guard let doc = PDFDocument(url: f), doc.pageCount > 0 else { fail("PDF 无法读取，请返回题页。"); return }
            let reader = PDFView()
            reader.displayMode = .singlePageContinuous; reader.displayDirection = .vertical; reader.autoScales = true
            reader.delegate = self; reader.document = doc
            pdf = reader; install(reader); panel.layoutIfNeeded()
            let fragment = URLComponents(url: dest.url, resolvingAgainstBaseURL: false)?.fragment ?? ""
            let pageText = fragment.split(separator: "&").first(where: { $0.hasPrefix("page=") })
            let requested = pageText.flatMap { Int($0.dropFirst(5)) } ?? 1
            let index = dest.pdfIndex ?? (min(max(requested,1),doc.pageCount) - 1)
            if let page = doc.page(at: index) { reader.go(to: page) }
            documentReady = true; setLearning(true)
            return
        }
        do {
            let controller = w.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: try s.bootstrapScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            w.isHidden = false; w.isUserInteractionEnabled = false; permittedLoad = dest.url
            activeNavigation = w.load(URLRequest(url: dest.url, cachePolicy: .reloadIgnoringLocalCacheData))
        } catch { fail("无法恢复本次练习的答题和草稿记录，已停止加载。\n\(error.localizedDescription)", terminal: true) }
    }

    func receive(_ message: WKScriptMessage) {
        guard !blocked, message.webView === web,
              message.frameInfo.isMainFrame, let source = message.frameInfo.request.url,
              let file = resources.page(source), ["html","htm"].contains(file.pathExtension.lowercased()) else { return }
        if message.name == "originalPracticeLearning" {
            guard file.lastPathComponent == "course.html", let here = position?.url,
                  resources.page(here) == file, let value = message.body as? Bool else { return }
            cardOpen = value
            if documentReady { setLearning(value) }
            return
        }
        guard message.name == "originalPracticeStore",
              let data = message.body as? [String: Any], let key = data["key"] as? String,
              let value = data["value"], value is NSNull || value is String, let store else { return }
        do { try store.apply(key: key, value: value as? String) }
        catch { fail("练习记录未能保存，已暂停作答。请退出后重开；本次未保存的操作不能计入完成。\n\(error.localizedDescription)", terminal: true) }
    }

    private func setLearning(_ active: Bool) {
        guard learningActive != active else { return }
        learningActive = active; learning(active)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !blocked, let url = action.request.url, resources.page(url) != nil else { decisionHandler(.cancel); return }
        if let target = action.targetFrame, !target.isMainFrame { decisionHandler(.cancel); return }
        if action.targetFrame != nil, url == permittedLoad {
            permittedLoad = nil; decisionHandler(.allow); return
        }
        guard action.sourceFrame.isMainFrame else { decisionHandler(.cancel); return }
        decisionHandler(.cancel)
        request(Place(url: url), move: .next)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !blocked, action.sourceFrame.isMainFrame, let u = action.request.url, resources.page(u) != nil {
            request(Place(url: u), move: .next)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation, let pos = position, let f = resources.page(pos.url) else { return }
        if pos.scroll != .zero { webView.scrollView.setContentOffset(pos.scroll, animated: false) }
        guard ["html","htm"].contains(f.pathExtension.lowercased()) else {
            webView.isUserInteractionEnabled = true; documentReady = true; setLearning(true); return
        }
        webView.evaluateJavaScript("window.__originalPracticeStorageReady === true") { [weak self] value,_ in
            guard let self, navigation === self.activeNavigation, !self.blocked else { return }
            if (value as? Bool) == true {
                webView.isUserInteractionEnabled = true; self.documentReady = true
                self.setLearning(f.lastPathComponent == "course.html" ? self.cardOpen : true)
            }
            else { self.fail("原题练习的记录保护未能启动，已停止作答。请退出后重开。", terminal: true) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailure(navigation, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailure(navigation, error) }
    private func navigationFailure(_ nav: WKNavigation?, _ error: Error) {
        guard nav === activeNavigation, !blocked, (error as NSError).code != NSURLErrorCancelled else { return }
        fail("这页资料没有加载成功。可以返回或再点科目首页。")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !blocked && !webView.isHidden { fail("练习页面已关闭。点科目首页可从已保存的记录继续。") }
    }

    // Local PDFs are study material, not another route to the system browser or remote documents.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}

    func tearDown() {
        documentReady = false; setLearning(false)
        web?.stopLoading(); web?.uiDelegate = nil; web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "originalPracticeStore")
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "originalPracticeLearning")
        messages.owner = nil
    }
}
