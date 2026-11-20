import UIKit
import SwiftUI
import WebKit
import Foundation

enum ConceptSubject: String { case circuit, mechanics; var shortTitle: String { rawValue } }

@main
@MainActor
final class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let token=String(UUID().uuidString.prefix(8))
    var submitted=false
    private func append(_ data:[String:Any]) {
        var d=data;d["run"]=token; d["wall"]=Date().timeIntervalSince1970
        guard let raw=try? JSONSerialization.data(withJSONObject:d),let line=String(data:raw,encoding:.utf8),
              let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else {return}
        let f=root.appendingPathComponent("wk-telemetry.jsonl")
        let old=(try? String(contentsOf:f,encoding:.utf8)) ?? ""
        try? (old+line+"\n").write(to:f,atomically:true,encoding:.utf8)
        NSLog("WKPROBE %@",line)
    }
    func application(_ app:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?) -> Bool {
        let win=UIWindow(frame:UIScreen.main.bounds)
        win.rootViewController=UIHostingController(rootView:OriginalPracticeView(subject:.circuit,onLearningChanged:{ [weak self] on in self?.append(["learning":on]) }))
        window=win;win.makeKeyAndVisible()
        append(["launched":true])
        for dt in [2,5,10,20,35,50] { DispatchQueue.main.asyncAfter(deadline:.now() + .seconds(dt)) { [weak self] in self?.snapshot(dt) } }
        return true
    }
    private func snapshot(_ dt:Int) {
        guard let win=window else{return}
        var q:[UIView]=[win],found:WKWebView?,labels:[String]=[]
        while let v=q.popLast(){if let z=v as? WKWebView {found=z}; if let lab=v as? UILabel, !lab.isHidden,let tx=lab.text { labels.append(tx) }; q+=v.subviews }
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        let f=root.appendingPathComponent("OriginalPracticeProgress/original-practice-v1.json")
        let disk=(try? String(contentsOf:f,encoding:.utf8)) ?? "(not found)"
        guard let w=found else {append(["t":dt,"wkFound":false,"labels":labels,"archive":disk]);return}
        append(["t":dt,"wkFound":true,"wkURL":w.url?.absoluteString ?? "(nil)","loading":w.isLoading,"progress":w.estimatedProgress,"bounds":NSStringFromCGRect(w.bounds),"frame":NSStringFromCGRect(w.frame),"interactive":w.isUserInteractionEnabled,"hidden":w.isHidden,"wkTitle":w.title ?? "(nil)","labels":labels,"archive":disk])
        let expr="""
        (()=>{let x={url:location.href,ready:document.readyState,title:document.title,body:document.body?.innerText||'',bridge:window.__originalPracticeStorageReady===true};try{x.stored=localStorage.getItem('real-bank-offline-v1:item/synthetic-probe')}catch(e){x.storeError=String(e)}return JSON.stringify(x)})()
        """
        w.evaluateJavaScript(expr){ [weak self,weak w] value,error in
            guard let self,let w else{return}; self.append(["t":dt,"eval":value as? String ?? "(nil)","err":error?.localizedDescription ?? ""])
            guard dt>=5 && w.isUserInteractionEnabled, !self.submitted, let txt=value as? String,let j=(try? JSONSerialization.jsonObject(with:Data(txt.utf8))) as? [String:Any], j["bridge"] as? Bool==true else{return}
            let t=j["title"] as? String
            if t=="SYNTH-HOME" { w.evaluateJavaScript("document.getElementById('enter').click();true"){ [weak self] v,e in self?.append(["action":"enter","ok":v as? Bool ?? false,"err":e?.localizedDescription ?? ""])} }
            else if t=="SYNTH-QUESTION" {
                self.submitted=true
                w.evaluateJavaScript("document.getElementById('answer').click();document.getElementById('feedback').textContent"){[weak self] v,e in self?.append(["action":"answer","feedback":v as? String ?? "", "err":e?.localizedDescription ?? ""])}
            }
        }
    }
}
