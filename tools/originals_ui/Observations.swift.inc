#if DEBUG && targetEnvironment(simulator)
// Appended only to a fresh Debug simulator checkout. Observes synthetic input; never writes learning state.
@MainActor
private enum WKOnlyDiagnostic {
    static var lines: [[String: Any]] = []
    static let active = ProcessInfo.processInfo.arguments.contains("--synthetic-originals-direct")
    static func event(_ name: String, _ details: [String: Any] = [:]) {
        guard active else { return }
        var r = details; r["event"] = name; r["uptime"] = ProcessInfo.processInfo.systemUptime; lines.append(r)
        do {
            let bytes = try JSONSerialization.data(withJSONObject: lines, options: [.sortedKeys])
            try bytes.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-originals-wk-diagnostic.json"), options: .atomic)
        } catch { NSLog("Synthetic WK diagnostic write failed: %@", error.localizedDescription) }
    }
    static func watch(_ controller: PracticeController) {
        guard active else {return}
        for offset in [0,2,5,15,35,65] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(offset)) { [weak controller] in
                guard let c=controller,let w=c.diagnosticWeb else {event("missingController",["offset":offset]);return}
                let f=Bundle.main.bundleURL.appendingPathComponent("OriginalPractice/course.html")
                event("nativeSnapshot",["offset":offset,"url":w.url?.absoluteString ?? "(nil)","isLoading":w.isLoading,
                    "bounds":NSStringFromCGRect(w.bounds),"scrollSize":NSStringFromCGSize(w.scrollView.contentSize),"onScreen":w.window != nil,
                    "progress":w.estimatedProgress,"userInteraction":w.isUserInteractionEnabled,"notice":c.diagnosticNotice,
                    "fileExists":FileManager.default.fileExists(atPath:f.path),"fileBytes":(try? Data(contentsOf:f).count) ?? -1,
                    "bundle":f.path,"documentReady":c.diagnosticReady])
                w.evaluateJavaScript("JSON.stringify({href:location.href,title:document.title,body:document.body?.innerText?.slice(0,240)||'',ready:window.__originalPracticeStorageReady===true,state:document.readyState,links:Array.from(document.links,a=>[a.textContent,a.href]).slice(0,4)})") { v,e in
                    event("domSnapshot",["offset":offset,"value":v as? String ?? "(nil)","error":e?.localizedDescription ?? ""])
                }
            }
        }
    }
}
@MainActor private extension PracticeController {
    var diagnosticWeb: WKWebView? { web }
    var diagnosticReady: Bool { documentReady }
    var diagnosticNotice: String { notice.isHidden ? "" : (notice.text ?? "") }
}
#endif
