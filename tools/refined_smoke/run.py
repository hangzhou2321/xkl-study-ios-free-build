"""Isolated hosted macOS test. Adds a Debug UI-test target in a temporary checkout, never to a Release IPA."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib, json, os, plistlib, re, shutil, subprocess, sys, platform
from xml.etree import ElementTree as ET

HERE=Path(__file__).resolve().parent
BUNDLE='local.xkl.study'
UI='RefinedSmokeUITests'
def cmd(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)
def capture(*args):
    return cmd(*args,capture_output=True,text=True).stdout.strip()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def add_test(root,dyld):
    # Parse the actual tracked candidate project; leave existing target/settings exactly as received.
    sys.path.insert(0,str(root/'tools'))
    from generate_xcode_project import plist,uid
    proj=root/'XKLStudy.xcodeproj';pbx=proj/'project.pbxproj'
    raw=json.loads(capture('plutil','-convert','json','-o','-','--',pbx));o=raw['objects']
    def add(k,isa,**kw):
        n=uid('original-smoke-'+k);assert n not in o;o[n]=dict(isa=isa,**kw);return n
    group=o[uid('group')]; products=o[uid('products')]; project=o[raw['rootObject']]; host=uid('target')
    assert o[host]['name']=='XKLStudy'
    dest=root/'RefinedSyntheticSmoke';assert not dest.exists()
    dest.mkdir(); fixtures(dest/'RefinedMemory')
    uit=HERE/(UI+'.swift');(dest/uit.name).write_text(uit.read_text().replace('SIMULATOR_18_5_SWIFT_ABSOLUTE',str(dyld)))
    original=(root/'App/StudyApp.swift').read_text();needle='if ProcessInfo.processInfo.arguments.contains("--effective-time-preview")'
    assert original.count(needle)==1
    diag=original.replace(needle,'if ProcessInfo.processInfo.arguments.contains("--refined-synthetic-course") {SyntheticCourseRoot()} else '+needle)+(HERE/'ProbeMain.inc').read_text()
    (dest/'ProbeMain.swift').write_text(diag)
    refs=[v for v in o.values() if v.get('isa')=='PBXFileReference' and v.get('path')=='StudyApp.swift'];assert len(refs)==1
    refs[0]['path']='../'+dest.name+'/ProbeMain.swift'
    folder=add('data','PBXFileReference',lastKnownFileType='folder',path='RefinedMemory',sourceTree='<group>')
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
    tree.write(proj/'xcshareddata/xcschemes/RefinedSynthetic.xcscheme',encoding='utf-8',xml_declaration=True)
    return sha(pbx)

def fixtures(where):
    where.mkdir()
    for k in ('computer','power'):
        cards=[dict(key='group-'+k,chapter='Synthetic',title='Synthetic '+k,evidence=dict(label='Synthetic',detail='Test only'),rows=[dict(ref='group-'+k+'#'+str(i),q=f'Synthetic {k} question {i}?',a=f'Synthetic {k} answer {i}.',kind='synthetic',how='A',note='',colors=[],core=[]) for i in (1,2,3)])]
        (where/(k+'.json')).write_text(json.dumps(dict(subject=k,baseSHA256='b'*64,cards=cards)),encoding='utf8')
def stage_old(where):
    where.mkdir(exist_ok=True,parents=True)
    for k in ('computer','power'):
        c=[dict(id=f'synthetic-{k}-{i}',chapterID='synthetic-chap',sourceGroupIDs=[f'group-{i}'],title=f'synthetic legacy {i}',prompt=f'Old {k} {i}?',answerSummary=f'Old {i}.',topicNumber=1,blocks=[],examples=[],sourceNotes=[],sourcePages=[1]) for i in range(2)]
        pkg=dict(format='xkl-handbook-cards-v1',subject=k,id='synthetic-'+k,title='Legacy synthetic '+k,revision='1.0.0',source=dict(title='Test only',fileName='synthetic.pdf',sha256='a'*64,pdfPageCount=1,includedPages=[1]),sourcePages=[],chapters=[dict(id='synthetic-chap',title='Synthetic chapter')],cards=c)
        (where/(k+'.xklflashcards')).write_text(json.dumps(pkg),encoding='utf8')
def run():
    import time,threading,base64,ctypes
    root=Path(sys.argv[1]).resolve();target=sys.argv[2];out=Path(sys.argv[3]).resolve();out.mkdir(exist_ok=True,parents=True)
    assert re.fullmatch('[a-f0-9]{40}',target) and capture('git','-C',root,'rev-parse','HEAD')==target and not capture('git','-C',root,'status','--porcelain')
    h={n:sha(root/'App'/n) for n in ('StudyApp.swift','ConceptView.swift','RefinedMemoryView.swift','RefinedMemoryStore.swift','ProfessionalRecallEngine.swift')}
    for n in ('RefinedMemoryStore.swift','RefinedMemoryView.swift'):assert n in (root/'XKLStudy.xcodeproj/project.pbxproj').read_text()
    rt=next(x for x in json.loads(capture('xcrun','simctl','list','-j','runtimes'))['runtimes'] if x.get('version')=='18.5' and x.get('isAvailable'))
    dyld=Path(rt['bundlePath'])/'Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift';assert (dyld/'libswiftWebKit.dylib').is_file()
    (out/'runtime.json').write_text(json.dumps(dict(path=str(dyld),libSHA=sha(dyld/'libswiftWebKit.dylib'),xctestChildKey='DYLD_FALLBACK_LIBRARY_PATH',simctlChildKey='SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH')))
    add_test(root,dyld)
    infos=json.loads(capture('xcrun','simctl','list','-j','devices','available'))['devices'];only=[(tuple(map(int,k.split('iOS-')[-1].split('-'))),d) for k,ds in infos.items() if 'iOS-' in k for d in ds if d['name'].startswith('iPhone')]
    latest=(18,5);assert any(rt==latest for rt,_ in only),list(infos);devices=[v for r,v in only if r==latest];d=next((v for v in devices if v['name'] in ['iPhone 16','iPhone 17']),devices[0]);u=d['udid']
    subprocess.run(['xcrun','simctl','boot',u]);dd=out.parent/'refined-ui-derived';common=['xcodebuild','-project',str(root/'XKLStudy.xcodeproj'),'-scheme','RefinedSynthetic','-configuration','Debug','-destination','platform=iOS Simulator,id='+u,'-derivedDataPath',str(dd),'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1']
    def build(args,file):
        with (out/file).open('w') as log:rc=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT).returncode
        if rc: print((out/file).read_text(errors='replace')[-6500:]);raise RuntimeError((file,rc))
    build(common+['build-for-testing'],'build.log')
    cmd('xcrun','simctl','bootstatus',u,'-b')
    app=dd/'Build/Products/Debug-iphonesimulator/XKLStudy.app';cmd('xcrun','simctl','install',u,app)
    data=Path(capture('xcrun','simctl','get_app_container',u,BUNDLE,'data'));stage_old(data/'Documents/HandbookCards')
    # Verify that actual app launches in the selected simulator with the runtime's own WebKit overlay.
    simenv=dict(os.environ,SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH=str(dyld))
    pp=subprocess.run(['xcrun','simctl','launch',u,BUNDLE],env=simenv,text=True,capture_output=True)
    (out/'warmup.log').write_text(str(pp.returncode)+' '+pp.stdout+' '+pp.stderr);time.sleep(3)
    subprocess.run(['xcrun','simctl','terminate',u,BUNDLE],capture_output=True)
    history=[];last={};finished=threading.Event()
    def monitor():
        while not finished.is_set():
            for sub in ('computer','power'):
                for path in ('RefinedMemory','HandbookWordRecall'):
                    f=data/'Library/Application Support'/path/sub/'current.json'
                    try:
                        if not f.is_file():continue
                        stamp=f.stat().st_mtime_ns
                        if last.get(str(f))==stamp:continue
                        raw=f.read_bytes();j=json.loads(raw);rec=j.get('record') if path=='RefinedMemory' else j['state']['word']
                        history.append(dict(t=time.time(),path=path,subject=sub,hash=hashlib.sha256(raw).hexdigest(),snap=hashlib.sha256(base64.b64decode(rec['snapshot'])).hexdigest(),submitted=len(rec['attempts']),presentation=rec.get('presentation')))
                        last[str(f)]=stamp
                    except (OSError,ValueError,KeyError):pass
            finished.wait(.08)
    th=threading.Thread(target=monitor,daemon=True);th.start()
    phase='testRealRoot'
    def ui(name,log):
        build(common+['-resultBundlePath',str(out.parent/(name+'.xcresult')),'-only-testing:'+UI+'/RefinedSmokeUITests/'+name,'test-without-building'],log)
    try:
        try: ui(phase,'ui.log')
        except RuntimeError:
            # Preserve data about the first failed path; no reset of any non-synthetic device or subject.
            assert 'RefinedSynthetic' in str(common)
            (out/'root-observations.json').write_text(json.dumps(history))
            crash=out/'crash';crash.mkdir(exist_ok=True)
            for f in (Path.home()/'Library/Logs/DiagnosticReports').glob('XKLStudy*'):
                if f.stat().st_size<=7000000:shutil.copy2(f,crash/f.name)
            subprocess.run(['xcrun','simctl','uninstall',u,BUNDLE],check=True);cmd('xcrun','simctl','install',u,app)
            data=Path(capture('xcrun','simctl','get_app_container',u,BUNDLE,'data'));stage_old(data/'Documents/HandbookCards')
            history.clear(); last.clear();phase='testSameCourseView';ui(phase,'ui-fallback.log')
    except Exception:
        shutil.make_archive(str(out/'built-synthetic-simulator'),'zip',root_dir=dd/'Build/Products')
        raise
    finally:
        finished.set();th.join();(out/'observations.json').write_text(json.dumps(history,indent=1))
    cp=root/'Sources/CPocket';lib=out.parent/'libreadpocket.dylib';cmd('clang','-O1','-dynamiclib','-I'+str(cp/'include'),'-I'+str(cp/'internal'),*cp.rglob('*.c'),'-o',lib)
    dll=ctypes.CDLL(str(lib));dll.xkl_engine_restore.argtypes=[ctypes.c_void_p,ctypes.c_size_t];dll.xkl_engine_restore.restype=ctypes.c_void_p
    dll.xkl_engine_event.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p];dll.xkl_engine_event.restype=ctypes.c_bool
    result={}
    for k in ('computer','power'):
        old=[x for x in history if x['path']=='HandbookWordRecall' and x['subject']==k and x['submitted']>=1]; assert old and len({x['hash'] for x in old})==1,(k,'legacy modified after seeded grade',old)
        events=[x for x in history if x['path']=='RefinedMemory' and x['subject']==k];assert any(x['submitted']==0 and x['presentation'] and x['presentation']['revealed'] for x in events)
        file=data/'Library/Application Support/RefinedMemory'/k/'current.json';r=json.loads(file.read_bytes())['record']; at=r['attempts'];assert len(at)==1 and at[0]['remembered']==False
        assert r['presentation'] and not r['presentation']['revealed']; s=base64.b64decode(r['snapshot']);assert hashlib.sha256(s).hexdigest()==r['snapshotSHA256'];handle=dll.xkl_engine_restore(s,len(s));assert handle
        ev=(ctypes.c_uint32*16)();a=at[0];assert dll.xkl_engine_event(handle,a['engineSequence']-1,ctypes.byref(ev)),a;assert ev[0]==a['engineSequence'] and ev[1] in (5,6) and r['cardIDs'][ev[3]]==a['cardID'] and ev[7]==a['beforeRevision'] and ev[8]==a['afterRevision']
        result[k]=dict(legacySnapshot=old[0]['snap'],legacyGraded=old[0]['submitted'],legacyArchiveUnchanged=True,sawRevealWithoutGrading=True,newWrongGrades=len(at),nativeEvent=list(ev),newPending=r['presentation'],courseSHA=sha(app/'RefinedMemory'/(k+'.json')))
    assert all(sha(root/'App'/n)==v for n,v in h.items());(out/'receipt.json').write_text(json.dumps(dict(release=target,sources=h,os=latest,device=d['name'],subjects=result,synthetic=True,route=phase),ensure_ascii=False,indent=1))
if __name__=='__main__':run()
