"""Interact with the *previously archived complete Debug simulator app*. The tiny build target only runs XCTest."""
import hashlib, urllib.request, tempfile, io, zipfile, json, os, subprocess, re, platform, sys, time
from pathlib import Path
from run import cmd,capture,sha,add_test,HERE,UI
ROOT=Path(sys.argv[1]).resolve(strict=True); OUT=Path(sys.argv[2]).resolve(); OUT.mkdir(parents=True)
RELEASE='8f2fdc67696ece384f8f6abca0a7227155e84bb0'; source='https://api.github.com/repos/hangzhou2321/xkl-study-ios-free-build/actions/artifacts/14596048337/zip'
assert capture('git','-C',ROOT,'rev-parse','HEAD')==RELEASE
class RemoveCredentials(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        assert newurl.startswith('https://')
        n=super().redirect_request(req,fp,code,msg,headers,newurl)
        if n:n.remove_header('Authorization')
        return n
op=urllib.request.build_opener(RemoveCredentials()); req=urllib.request.Request(source,headers={'Authorization':'Bearer '+os.environ.pop('ARTIFACT_TOKEN'),'User-Agent':'synthetic-wk-ui-replay'})
with op.open(req,timeout=60)as r:raw=r.read(40*1024*1024)
assert hashlib.sha256(raw).hexdigest()=='1a59438d9b6552dfbd9ca7e9028bea84af5c1960881a9bc06ca244539c128354'
outer=zipfile.ZipFile(io.BytesIO(raw)); pre=json.loads(outer.read('prelaunch.json'));inner=outer.read('synthetic-simulator-app.zip')
assert hashlib.sha256(inner).hexdigest()==pre['simulatorApp']=='3f50c677e351493b29031935a36b4387cc96158ec39ccebc2cbf4eb0c0d7cb1b'
assert pre['source']==RELEASE and pre['syntheticOnly']
tmp=OUT.parent/'verified-replay-input';tmp.mkdir();binary=tmp/'input.zip';binary.write_bytes(inner);cmd('ditto','-x','-k',binary,tmp)
actualApp=tmp/'XKLStudy.app';assert actualApp.is_dir()
for f in ('course.html','main.html'):assert sha(actualApp/'OriginalPractice'/f)==sha(HERE/'OriginalPractice'/f)
udid=capture('xcrun','simctl','create','Full-UI-Artifact-Replay',pre['device'],pre['runtime']);cmd('xcrun','simctl','boot',udid)
sys.path.insert(0,str(ROOT/'tools'));from generate_xcode_project import uid,plist
from capture_professional_question_previews import simulator_webkit_workaround
runtime=next(x for x in json.loads(capture('xcrun','simctl','list','--json','runtimes'))['runtimes'] if x['identifier']==pre['runtime'])
env,workaround=simulator_webkit_workaround(runtime); assert workaround['applied']
add_test(ROOT)
project=ROOT/'XKLStudy.xcodeproj/project.pbxproj';data=json.loads(capture('plutil','-convert','json','-o','-','--',project));o=data['objects'];host=o[uid('target')]
# The new seed target has a DISTINCT bundle identifier; Xcode may install it but cannot replace the checked real app.
seed=ROOT/'App/ReplaySeed.swift';seed.write_text('import SwiftUI\n@main struct ReplaySeed:App{var body:some Scene{WindowGroup{Text("XCTest seed; not the app under test")}}}')
ref=uid('replay-driver-seed-src');build=uid('replay-driver-seed-build')
o[ref]=dict(isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='ReplaySeed.swift',sourceTree='<group>')
o[build]=dict(isa='PBXBuildFile',fileRef=ref); o[uid('appgroup')]['children'].append(ref)
for ph in host['buildPhases']:
    phase=o[ph]; phase['files']=[build] if phase['isa']=='PBXSourcesBuildPhase' else []
host['dependencies']=[];host['packageProductDependencies']=[]
o[data['rootObject']]['packageReferences']=[];o[data['rootObject']]['targets']=[uid('target'),uid('original-smoke-target')]
for cl in o[host['buildConfigurationList']]['buildConfigurations']:
    b=o[cl]['buildSettings'];b.pop('INFOPLIST_FILE',None);b.pop('ASSETCATALOG_COMPILER_APPICON_NAME',None)
    b.update(PRODUCT_BUNDLE_IDENTIFIER='local.xkl.synthetic.replayseed',GENERATE_INFOPLIST_FILE='YES')
project.write_text('// !$*UTF8*$!\n'+plist(data)+'\n')
sw=ROOT/'OriginalsSyntheticSmoke'/(UI+'.swift');code=sw.read_text().replace('private let app = XCUIApplication()','private let app = XCUIApplication(bundleIdentifier: "local.xkl.study")')
code=code.replace('waitForExistence(timeout: 20)','waitForExistence(timeout: 65)')
code=code.replace('        app.launchArguments =','        app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = '+json.dumps(env['SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH'])+'\n        app.launchArguments =').replace('web.links[','app.links[').replace('web.buttons[','app.buttons[')
code=code.replace('app.webViews.firstMatch.descendants(matching: .any)','app.descendants(matching: .any)');sw.write_text(code)
cmd('xcrun','simctl','bootstatus',udid,'-b');cmd('xcrun','simctl','install',udid,actualApp)
result=OUT/'Replay.xcresult'
args=['xcodebuild','-project',str(ROOT/'XKLStudy.xcodeproj'),'-scheme','OriginalsSynthetic','-configuration','Debug','-destination','platform=iOS Simulator,id='+udid,
      '-sdk','iphonesimulator','-derivedDataPath',str(tmp/'Derived'),'-resultBundlePath',str(result),'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES','COMPILER_INDEX_STORE_ENABLE=NO',
      '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-only-testing:'+UI+'/'+UI+'/testSubjectNavigationAssistedResponsesAndColdReopen','test']
with (OUT/'ui-test.log').open('w')as log:
    ret=subprocess.run(args,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
log=(OUT/'ui-test.log').read_text(errors='replace')
if ret.returncode:
    print('\n'.join(l for l in log.splitlines() if 'failed -' in l or ': error:' in l)[-4000:]);sys.exit(ret.returncode)
assert '** TEST SUCCEEDED **' in log and re.search(r'Executed 1 test, with 0 failures',log)
container=Path(capture('xcrun','simctl','get_app_container',udid,'local.xkl.study','data'))
disk=container/'Library/Application Support/OriginalPracticeProgress/original-practice-v1.json'; archive=json.loads(disk.read_bytes())
answers={k:json.loads(v)for k,v in archive['entries'].items()}; assert set(answers)=={'real-bank-offline-v1:item/ui-circuit','real-bank-offline-v1:item/ui-mechanics'}
assert all(v['questionID']=='synthetic-square' and v['hint'] is True and v['choice']=='B' and v['queryRewriteSupport'] in ('blocked','allowed') for v in answers.values())
actual=Path(capture('xcrun','simctl','get_app_container',udid,'local.xkl.study','app'));assert sha(actual/'XKLStudy')==sha(actualApp/'XKLStudy')
(OUT/'simulator-receipt.json').write_text(json.dumps(dict(status='PASS_REAL_FULL_APP_XCUI_SYNTHETIC',release=RELEASE,previousBuildRun=44660058225,
    previousArtifactSHA256=hashlib.sha256(raw).hexdigest(),testedBinary=sha(actual/'XKLStudy'),mode='Normal RootView; no automatic sheet argument; real XCUI taps; simulator-only WebKit runtime workaround',
    subjects=['circuit','mechanics'],subjectSelection=True,problemFirst=True,nativeBackRecentQuestion=True,coldAppRelaunch=True,
    archiveSHA256=sha(disk),entries=answers,os=runtime['version'],physicalDeviceTested=False,privateMaterialUsed=False),indent=2))
