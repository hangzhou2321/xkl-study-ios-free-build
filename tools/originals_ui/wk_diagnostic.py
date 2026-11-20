"""Trace real WK callbacks in an explicitly patched Debug simulator build. No shipping target is changed."""
from pathlib import Path
import subprocess,sys,os,platform,time,json,hashlib,shutil,uuid
from run import cmd,capture,sha,add_test
HERE=Path(__file__).resolve().parent
ROOT=Path(sys.argv[1]).resolve(strict=True);EXPECTED=sys.argv[2];OUT=Path(sys.argv[3]).resolve(); OUT.mkdir(parents=True,exist_ok=True)
assert sys.platform=='darwin' and capture('git','-C',ROOT,'rev-parse','HEAD')==EXPECTED and not capture('git','-C',ROOT,'status','--porcelain')
sys.path.insert(0,str(ROOT/'tools'));from capture_professional_question_previews import select_device,simulator_webkit_workaround
# In the CI checkout only, observe callback state. The production guards, storage, scheme and UI controllers stay in place.
# Catch target SDK differences in the diagnostic-only observers before the expensive whole-app build.
sdk=capture('xcrun','--sdk','iphonesimulator','--show-sdk-path')
probe=OUT.parent/'diagnostic-observer-preflight.swift'
probe.write_text('import UIKit\nimport WebKit\n@MainActor private final class PracticeController: UIViewController { private var web: WKWebView?; private var documentReady=false; private let notice=UILabel() }\n'+(HERE/'Observations.swift.inc').read_text())
cmd('xcrun','swiftc','-typecheck','-swift-version','5','-D','DEBUG','-sdk',sdk,'-target',platform.machine()+'-apple-ios17.0-simulator',probe)
files=['StudyApp.swift','OriginalPracticeView.swift','ConceptView.swift'];orig={f:(ROOT/'App'/f).read_text() for f in files}
def sub(s,a,b):
    assert s.count(a)==1,(a,s.count(a));return s.replace(a,b)
# Start at the real RootView professional tab; present through the same @State used by the shipped entry button.
arg='ProcessInfo.processInfo.arguments.contains("--synthetic-originals-sheet")'
s=sub(orig[files[0]],'@State private var selectedTab = 5','@State private var selectedTab: Int = '+arg+' ? 4 : 5')
s=sub(s,'@State private var subject: ConceptSubject = .computer','@State private var subject: ConceptSubject = '+arg+' ? .circuit : .computer')
(ROOT/'App'/files[0]).write_text(s)
s=sub(orig[files[2]],'.sheet(item: $originalPracticeSubject, onDismiss:', '.onAppear { if '+arg+' && subject == .circuit { DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { originalPracticeSubject = subject } } }\n        .sheet(item: $originalPracticeSubject, onDismiss:')
(ROOT/'App'/files[2]).write_text(s)
t=orig[files[1]]
pairs=[
('web = w; install(w)','web = w; install(w); WKOnlyDiagnostic.watch(self); WKOnlyDiagnostic.event("webInstalled")'),
('do {\n            var data = try Data(contentsOf: f, options: .mappedIfSafe)','do {\n            WKOnlyDiagnostic.event("schemeStart",["url":u.absoluteString,"file":f.lastPathComponent,"mime":mime]); var data = try Data(contentsOf: f, options: .mappedIfSafe)'),
('task.didReceive(response); task.didReceive(data); task.didFinish()','WKOnlyDiagnostic.event("schemeRespond",["bytes":data.count,"url":u.absoluteString]); task.didReceive(response); task.didReceive(data); task.didFinish()'),
('guard !blocked, let url = action.request.url, resources.page(url) != nil else','WKOnlyDiagnostic.event("policy",["url":action.request.url?.absoluteString ?? "(nil)","permitted":permittedLoad?.absoluteString ?? "(nil)","targetMain":action.targetFrame?.isMainFrame.description ?? "(nil)","sourceMain":action.sourceFrame.isMainFrame,"fileExists":action.request.url.flatMap { resources.page($0) } != nil]); guard !blocked, let url = action.request.url, resources.page(url) != nil else'),
('activeNavigation = w.load(URLRequest(url: dest.url, cachePolicy: .reloadIgnoringLocalCacheData))','WKOnlyDiagnostic.event("requestLoad",["url":dest.url.absoluteString]); activeNavigation = w.load(URLRequest(url: dest.url, cachePolicy: .reloadIgnoringLocalCacheData))'),
('func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {','func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { WKOnlyDiagnostic.event("didStart",["url":webView.url?.absoluteString ?? "(nil)"]) }\n    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { WKOnlyDiagnostic.event("didCommit",["url":webView.url?.absoluteString ?? "(nil)"]) }\n    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { WKOnlyDiagnostic.event("didFinish",["url":webView.url?.absoluteString ?? "(nil)","matches":navigation === activeNavigation])'),
('guard nav === activeNavigation, !blocked, (error as NSError).code != NSURLErrorCancelled','WKOnlyDiagnostic.event("navigationError",["code":(error as NSError).code,"domain":(error as NSError).domain,"message":error.localizedDescription]); guard nav === activeNavigation, !blocked, (error as NSError).code != NSURLErrorCancelled'),
('func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {','func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { WKOnlyDiagnostic.event("processTerminated")')]
for a,b in pairs:t=sub(t,a,b)
(ROOT/'App'/files[1]).write_text(t+'\n'+(HERE/'Observations.swift.inc').read_text())
# Emit only the diagnostic source delta in this clean public checkout (never private materials).
(OUT/'debug-observation.patch').write_text(capture('git','-C',ROOT,'diff','--','App'))
add_test(ROOT); name,runtime,kind,info=select_device();launchEnv,workaround=simulator_webkit_workaround(info)
udid=capture('xcrun','simctl','create','Synthetic-Originals-DOM-'+uuid.uuid4().hex[:6],kind,runtime)
print('device',name,runtime,info['version'],udid,flush=True)
cmd('xcrun','simctl','boot',udid)
dd=OUT.parent/'diag-derived'
args=['xcodebuild','-project',str(ROOT/'XKLStudy.xcodeproj'),'-scheme','XKLStudy','-configuration','Debug','-sdk','iphonesimulator',
      '-destination','generic/platform=iOS Simulator','-derivedDataPath',str(dd),'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=',
      'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES','COMPILER_INDEX_STORE_ENABLE=NO','build']
with (OUT/'compile.log').open('w') as log:
    result=subprocess.run(args,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(l for l in (OUT/'compile.log').read_text(errors='replace').splitlines() if ': error:' in l)[-3000:]);raise SystemExit(result.returncode)
app=dd/'Build/Products/Debug-iphonesimulator/XKLStudy.app';assert all(sha(app/'OriginalPractice'/x)==sha(HERE/'OriginalPractice'/x)for x in ('course.html','main.html'))
# Keep this exact Debug simulator app with only the two public synthetic HTML files. A launch diagnostic can then be rerun without another build.
cmd('/usr/bin/ditto','-c','-k','--keepParent',app,OUT/'synthetic-simulator-app.zip')
(OUT/'prelaunch.json').write_text(json.dumps(dict(source=EXPECTED,runtime=runtime,device=kind,simulatorApp=sha(OUT/'synthetic-simulator-app.zip'),syntheticOnly=True,workaround=workaround),indent=2))
cmd('xcrun','simctl','bootstatus',udid,'-b');cmd('xcrun','simctl','install',udid,app)
ud=Path(capture('xcrun','simctl','get_app_container',udid,'local.xkl.study','data'));capturefile=ud/'tmp/synthetic-originals-wk-diagnostic.json'
modes=([('runtime-library',launchEnv)] if launchEnv else [])+[('normal',{})]; states={}
for name,ev in modes:
    capturefile.unlink(missing_ok=True); out=OUT/name;out.mkdir(exist_ok=True)
    launch=subprocess.run(['xcrun','simctl','launch',udid,'local.xkl.study','--synthetic-originals-sheet'],env=os.environ|ev,capture_output=True,text=True,timeout=120)
    (out/'launch.txt').write_text(launch.stdout+launch.stderr)
    if launch.returncode:
        paths=[Path.home()/'Library/Logs/DiagnosticReports',Path.home()/'Library/Developer/CoreSimulator/Devices'/udid/'data/Library/Logs/CrashReporter']
        for folder in paths:
            if folder.exists():
                for cr in sorted(folder.glob('XKLStudy*'),key=lambda q:q.stat().st_mtime,reverse=True)[:3]:
                    if cr.is_file():shutil.copy2(cr,out/cr.name)
        try:
            lastlog=subprocess.run(['xcrun','simctl','spawn',udid,'log','show','--style','compact','--last','2m','--predicate',
                '(process == "XKLStudy") OR (eventMessage CONTAINS[c] "libswiftWebKit")'],timeout=20,capture_output=True,text=True)
            (out/'sim-launch.log').write_text(lastlog.stdout[-40000:]+lastlog.stderr[-500:])
        except subprocess.TimeoutExpired:pass
        states[name]={'DOMCourseReady':False,'snapshots':0,'events':['launchFailed'],'launchCode':launch.returncode}
        if capturefile.exists():shutil.copy2(capturefile,out/'wk-events.json')
        else:(out/'wk-events.json').write_text('[]')
        print(name,states[name],flush=True);continue
    timeout=time.monotonic()+105; seen=set();lines=[]
    while time.monotonic()<timeout:
        try:lines=json.loads(capturefile.read_bytes())
        except (OSError,ValueError):time.sleep(1);continue
        available={x.get('offset')for x in lines if x['event']=='domSnapshot'}
        for n in (2,5,15,65):
            if n not in seen and n in available:
                seen.add(n);cmd('xcrun','simctl','io',udid,'screenshot',out/('screen-%ss.png'%n))
        if 65 in available:break
        time.sleep(1)
    (out/'wk-events.json').write_text(json.dumps(lines,ensure_ascii=False,indent=1))
    ps=subprocess.run(['xcrun','simctl','spawn',udid,'launchctl','print','system'],capture_output=True,text=True)
    (out/'webkit-process-list.txt').write_text('\n'.join(l for l in ps.stdout.splitlines() if 'webcontent' in l.lower() or 'webkit' in l.lower())[:30000])
    ready=[x for x in lines if x['event']=='domSnapshot' and '"ready":true' in x.get('value','') and 'Open synthetic problem circuit' in x.get('value','')]
    states[name]={'DOMCourseReady':bool(ready),'snapshots':len([x for x in lines if x['event']=='domSnapshot']),'events':[x['event'] for x in lines],'firstReadyOffset':ready[0]['offset'] if ready else None}
    print(name,states[name],flush=True)
    subprocess.run(['xcrun','simctl','terminate',udid,'local.xkl.study'],capture_output=True)
(OUT/'result.json').write_text(json.dumps(dict(release=EXPECTED,debugObservationOnly=True,entry='real RootView professional tab and production sheet; launch arg sets initial route and requests same state as entry button',host=platform.machine(),runtime=runtime,model=kind,os=info['version'],states=states,simulatorWorkaround=workaround,physicalDevice=False),indent=2))
assert any(s['snapshots']>=3 for s in states.values()),'no mode returned actual DOM snapshots; see launch logs and reports'
