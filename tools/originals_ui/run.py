"""Isolated hosted macOS test. Adds a Debug UI-test target in a temporary checkout, never to a Release IPA."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib, json, os, plistlib, re, shutil, subprocess, sys, platform
from xml.etree import ElementTree as ET

HERE=Path(__file__).resolve().parent
BUNDLE='local.xkl.study'
UI='OriginalPracticeSmokeUITests'
def cmd(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)
def capture(*args):
    return cmd(*args,capture_output=True,text=True).stdout.strip()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def add_test(root):
    # Parse the actual tracked candidate project; leave existing target/settings exactly as received.
    sys.path.insert(0,str(root/'tools'))
    from generate_xcode_project import plist,uid
    proj=root/'XKLStudy.xcodeproj';pbx=proj/'project.pbxproj'
    raw=json.loads(capture('plutil','-convert','json','-o','-','--',pbx));o=raw['objects']
    def add(k,isa,**kw):
        n=uid('original-smoke-'+k);assert n not in o;o[n]=dict(isa=isa,**kw);return n
    group=o[uid('group')]; products=o[uid('products')]; project=o[raw['rootObject']]; host=uid('target')
    assert o[host]['name']=='XKLStudy'
    dest=root/'OriginalsSyntheticSmoke';assert not dest.exists()
    shutil.copytree(HERE/'OriginalPractice',dest/'OriginalPractice')
    shutil.copy2(HERE/(UI+'.swift'),dest/(UI+'.swift'))
    folder=add('data','PBXFileReference',lastKnownFileType='folder',path='OriginalPractice',sourceTree='<group>')
    o[uid('resources')]['files'].append(add('include-data','PBXBuildFile',fileRef=folder))
    s=add('swift','PBXFileReference',lastKnownFileType='sourcecode.swift',path=UI+'.swift',sourceTree='<group>')
    group['children'].append(add('group','PBXGroup',children=[folder,s],path=dest.name,sourceTree='<group>'))
    product=add('prod','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex=0,path=UI+'.xctest',sourceTree='BUILT_PRODUCTS_DIR')
    products['children'].append(product)
    src=add('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[add('include-swift','PBXBuildFile',fileRef=s)],runOnlyForDeploymentPostprocessing=0)
    framework=add('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
    settings=dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='local.xkl.originalspractice.smoketests',
                  GENERATE_INFOPLIST_FILE='YES',SWIFT_VERSION='5.0',TARGETED_DEVICE_FAMILY='1,2',IPHONEOS_DEPLOYMENT_TARGET='17.0',
                  TEST_TARGET_NAME='XKLStudy',ENABLE_TESTING_SEARCH_PATHS='YES',SDKROOT='iphoneos',
                  LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'],SKIP_INSTALL='YES')
    configs=[add('config-'+n,'XCBuildConfiguration',name=n,buildSettings=settings) for n in ('Debug','Release')]
    cl=add('configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
    proxy=add('proxy','PBXContainerItemProxy',containerPortal=raw['rootObject'],proxyType=1,remoteGlobalIDString=host,remoteInfo='XKLStudy')
    dep=add('dep','PBXTargetDependency',target=host,targetProxy=proxy)
    target=add('target','PBXNativeTarget',buildConfigurationList=cl,buildPhases=[src,framework],buildRules=[],dependencies=[dep],name=UI,
               productName=UI,productReference=product,productType='com.apple.product-type.bundle.ui-testing')
    project['targets'].append(target);project['attributes'].setdefault('TargetAttributes',{})[target]=dict(CreatedOnToolsVersion='16.0',TestTargetID=host)
    pbx.write_text('// !$*UTF8*$!\n'+plist(raw)+'\n',encoding='utf8')
    scheme=proj/'xcshareddata/xcschemes/XKLStudy.xcscheme';tree=ET.parse(scheme);sc=tree.getroot()
    entry=ET.SubElement(sc.find('BuildAction/BuildActionEntries'),'BuildActionEntry',dict(buildForTesting='YES',buildForRunning='NO',buildForProfiling='NO',buildForArchiving='NO',buildForAnalyzing='NO'))
    attr=dict(BuildableIdentifier='primary',BlueprintIdentifier=target,BuildableName=UI+'.xctest',BlueprintName=UI,ReferencedContainer='container:XKLStudy.xcodeproj')
    ET.SubElement(entry,'BuildableReference',attr)
    item=ET.SubElement(sc.find('TestAction/Testables'),'TestableReference',skipped='NO')
    ET.SubElement(item,'BuildableReference',attr)
    tree.write(proj/'xcshareddata/xcschemes/OriginalsSynthetic.xcscheme',encoding='utf-8',xml_declaration=True)
    return sha(pbx)

def run():
    if sys.platform!='darwin': raise SystemExit('A hosted Apple simulator is required')
    root=Path(sys.argv[1]).resolve(strict=True);expected=sys.argv[2];out=Path(sys.argv[3]).resolve();out.mkdir(parents=True,exist_ok=True)
    assert len(expected)==40 and re.fullmatch('[a-f0-9]{40}',expected) and capture('git','-C',root,'rev-parse','HEAD')==expected
    assert not capture('git','-C',root,'status','--porcelain')
    app_sources={n:sha(root/'App'/n) for n in ('StudyApp.swift','ConceptView.swift','OriginalPracticeView.swift','OriginalPracticeStorage.swift')}
    checked_project=sha(root/'XKLStudy.xcodeproj/project.pbxproj');mod=add_test(root)
    infos=json.loads(capture('xcrun','simctl','list','-j','devices','available'))['devices']
    devices=[(tuple(map(int,k.split('iOS-')[-1].split('-'))),d)for k,ds in infos.items() if 'iOS-' in k for d in ds if 'iPhone' in d['name'] and d['isAvailable']]
    assert devices
    latest=max(x[0] for x in devices);available=[d for r,d in devices if r==latest];device=next((d for d in available if d['name'] in ('iPhone 16','iPhone 17','iPhone 15')),available[0])
    runtime_id=next(k for k,ds in infos.items() if any(d['udid']==device['udid'] for d in ds))
    udid=capture('xcrun','simctl','create','Synthetic-Original-Practice',device['deviceTypeIdentifier'],runtime_id)
    cmd('xcrun','simctl','boot',udid);cmd('xcrun','simctl','bootstatus',udid,'-b')
    result=out/'Smoke.xcresult';dd=out.parent/'originals-smoke-derived'
    args=['xcodebuild','-project',str(root/'XKLStudy.xcodeproj'),'-scheme','OriginalsSynthetic','-configuration','Debug',
          '-destination','platform=iOS Simulator,id='+udid,'-derivedDataPath',str(dd),'-resultBundlePath',str(result),
          'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
          '-only-testing:'+UI+'/OriginalPracticeSmokeUITests/testSubjectNavigationAssistedResponsesAndColdReopen','test']
    with (out/'ui-test.log').open('w',encoding='utf8') as log:
        r=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT)
    log=(out/'ui-test.log').read_text(encoding='utf8',errors='replace')
    if r.returncode:print(log[-8000:]);raise SystemExit(r.returncode)
    assert '** TEST SUCCEEDED **' in log and 'testSubjectNavigationAssistedResponsesAndColdReopen' in log and re.search(r'Executed 1 test, with 0 failures',log),log[-4000:]
    data_root=Path(capture('xcrun','simctl','get_app_container',udid,BUNDLE,'data'))
    progress=data_root/'Library/Application Support/OriginalPracticeProgress/original-practice-v1.json'
    app_dir=Path(capture('xcrun','simctl','get_app_container',udid,BUNDLE,'app'))
    archive=json.loads(progress.read_bytes()); expected_keys={'real-bank-offline-v1:item/ui-'+s for s in ('circuit','mechanics')}
    assert archive['version']==1 and set(archive['entries'])==expected_keys
    decoded={k:json.loads(x) for k,x in archive['entries'].items()}
    assert all(v.get('questionID')=='synthetic-square' and v.get('hint') is True and v.get('choice')=='B' and v.get('queryRewriteSupport') in ('allowed','blocked') for v in decoded.values())
    html={n:sha(HERE/'OriginalPractice'/n) for n in ('course.html','main.html')}
    assert html=={n:sha(app_dir/'OriginalPractice'/n) for n in html}
    assert all(sha(root/'App'/n)==v for n,v in app_sources.items())
    info=plistlib.loads((app_dir/'Info.plist').read_bytes())
    receipt=dict(status='PASS_REAL_APPLE_SIMULATOR_SYNTHETIC',releaseSource=expected,appVersion=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
                 releaseSourcesUnmodified=app_sources,releaseProject=checked_project,simulatorOnlyProject=mod,syntheticFixtures=html,
                 osRuntime='.'.join(map(str,latest)),deviceType=device['name'],testedThrough='RootView → 专业课 → 分科 → OriginalPracticeView → WKWebView/course.html → main.html',
                 evidence=decoded,diskArchiveSHA256=sha(progress),xcode=capture('xcodebuild','-version'),utc=datetime.now(timezone.utc).isoformat(),
                 nativeBackFragmentCheckedFor=['circuit','mechanics'],coldAppLaunchCheckedFor=['circuit','mechanics'],realPrivateMaterialsUsed=False,physicalDeviceTested=False)
    (out/'simulator-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf8');print(json.dumps(receipt,ensure_ascii=False))
if __name__=='__main__': run()
