#!/usr/bin/env python3
"""Synthetic-only, real coordinate UI test against the ordinary app root."""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from capture_professional_question_previews import select_device, simulator_webkit_workaround, sim

OUT = ROOT / 'build/outline-related-uitest'
BUNDLE = 'local.xkl.study'

def logged(args, name, env, timeout=1200):
    with (OUT / name).open('w', encoding='utf8') as f:
        process = subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout)
    if process.returncode:
        raise RuntimeError('Command failed; inspect ' + name)

def sha(data): return hashlib.sha256(data).hexdigest()

def load_container(device):
    return Path(sim('get_app_container', device, BUNDLE, 'data').strip()).resolve()

def get_current(container):
    return (container / 'Library/Application Support/HandbookWordRecall/computer/current.json').read_bytes()

def events(container):
    p=container / 'Library/Application Support/HandbookWordRecall/computer/related-question-events'
    return sorted(p.glob('*.json')) if p.exists() else []

def check_recall_without_new_ratings(before, after):
    a=json.loads(before)['state']; b=json.loads(after)['state']
    for key in ('originalCardIDs','frozenCard','frozenToken','frozenGuide'):
        if a.get(key)!=b.get(key): raise RuntimeError('Recall card or frozen presentation changed: '+key)
    for key in ('cardIDs','attempts','presentation'):
        if a['word'].get(key)!=b['word'].get(key): raise RuntimeError('Recall IDs, grades or active presentation changed: '+key)

def main():
    if platform.system() != 'Darwin': raise RuntimeError('Requires macOS')
    os.chdir(ROOT); OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, info = select_device()
    if name != 'iPhone SE (3rd generation)': raise RuntimeError('Compact iPhone SE 3 unavailable')
    launch_env, workaround = simulator_webkit_workaround(info)
    env = dict(os.environ)
    fallback=launch_env.get('SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH', '')
    test_path=ROOT/'tools/guide_ui_test/GuideDisclosureUITests.swift'
    template=test_path.read_text(encoding='utf8'); marker='"__GUIDE_TEST_FALLBACK_PLACEHOLDER__"'
    assert template.count(marker)==1
    test_path.write_text(template.replace(marker,json.dumps(fallback)),encoding='utf8')
    subprocess.run(['python3','tools/guide_ui_test/generate_project.py','--without-personal-resources'],check=True,env=env)
    device=sim('create','OutlineRelated-'+uuid.uuid4().hex[:12],kind,runtime).strip()
    report={'status':'INCOMPLETE','syntheticOnly':True,'physicalDeviceTested':False,'device':name,
            'configuration':'Debug','simulatorWorkaround':workaround,'cases':{}}
    try:
        sim('boot',device); sim('bootstatus',device,'-b')
        subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',device],check=True)
        base=['xcodebuild','-project','XKLStudy.xcodeproj','-scheme','XKLStudy','-configuration','Debug',
              '-destination','platform=iOS Simulator,id='+device,'-derivedDataPath',str(OUT/'DerivedData'),
              'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=',
              'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES']
        logged(base+['build-for-testing'],'build.log',env)
        app=OUT/'DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app'
        assert app.is_dir(); sim('install',device,str(app))
        container=load_container(device)
        capture=str(uuid.uuid4())
        subprocess.run(['xcrun','simctl','launch','--terminate-running-process',device,BUNDLE,
                        '--handbook-card-preview','--case=outline-question','--subject=computer',
                        '--capture-id='+capture],check=True,capture_output=True,text=True,env={**env,**launch_env},timeout=180)
        deadline=time.monotonic()+180; fixture=None
        while time.monotonic()<deadline:
            for candidate in (container/'tmp').glob('synthetic-handbook-computer-*'):
                f=candidate/'HandbookWordRecall/computer/current.json'
                try:
                    obj=json.loads(f.read_text(encoding='utf8'))
                    package=obj['state']['package']
                    if len(package['cards'])==2 and len(package.get('relatedQuestions',[]))==1 and len(package['memoryGuides'][0]['rows'])==4:
                        fixture=candidate; break
                except (OSError,ValueError,KeyError,TypeError): pass
            if fixture: break
            time.sleep(.25)
        if not fixture: raise RuntimeError('Synthetic fixture did not become ready')
        try: sim('terminate',device,BUNDLE)
        except subprocess.CalledProcessError: pass
        support=container/'Library/Application Support'; support.mkdir(parents=True,exist_ok=True)
        destination=support/'HandbookWordRecall'
        if destination.exists(): raise RuntimeError('Fresh simulator has preexisting records')
        shutil.copytree(fixture/'HandbookWordRecall', destination)
        baseline=get_current(container)
        assert not events(container)
        phase_tests=[('view', ['testOpenAndCloseDoesNotScore','testCardWithoutQuestionHasNoSideButton']),
                     ('recall',['testNormalAndFullscreenRecallQuestionEntry']),
                     ('submit',['testSubmitCreatesOneRealAttempt'])]
        for phase, tests in phase_tests:
            result=OUT/(phase+'.xcresult')
            args=base+['test-without-building','-resultBundlePath',str(result),'-parallel-testing-enabled','NO']
            args+=['-only-testing:GuideDisclosureUITests/GuideDisclosureUITests/'+x for x in tests]
            args+=['-test-timeouts-enabled','YES','-default-test-execution-time-allowance','180',
                   '-maximum-test-execution-time-allowance','240']
            try: logged(args,phase+'.log',env)
            finally:
                if result.exists():
                    target=OUT/(phase+'-attachments');target.mkdir(exist_ok=True)
                    subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),
                                    '--output-path',str(target)],capture_output=True,text=True)
            actual=load_container(device)
            current=get_current(actual)
            found=events(actual)
            if phase=='view':
                if current!=baseline: raise RuntimeError('Recall state changed during directory preview')
                if found: raise RuntimeError('Viewing or closing created a score')
                report['cases'][phase]={'passed':True,'recallFileUnchanged':True,'newAttempts':0,
                                        'buttonHiddenWhenNoQuestions':True,'noTextOverlap':True,
                                        'buttonAtLeast44pt':True,'answerWidthAbove150pt':True}
            elif phase=='recall':
                check_recall_without_new_ratings(baseline,current)
                if found: raise RuntimeError('Opening questions during recall created a score')
                report['cases'][phase]={'passed':True,'sourceIDsRatingsFrozenPresentationUnchanged':True,
                                        'normalAndFullscreenClickable':True,'buttonAtLeast44pt':True,
                                        'noTextOverlap':True,'newAttempts':0}
                baseline=current
            else:
                if current!=baseline: raise RuntimeError('Recall state changed while submitting question')
                if len(found)!=1: raise RuntimeError('Expected exactly one related-question attempt')
                e=json.loads(found[0].read_text(encoding='utf8'))
                if e.get('questionID')!='synthetic-question' or e.get('cardID')!='synthetic-handbook-first' or e.get('cardAnswerWasVisible') is not True or e.get('correct') is not True:
                    raise RuntimeError('Attempt does not reflect viewed answer and actual selection')
                report['cases'][phase]={'passed':True,'recallFileUnchanged':True,'newAttempts':1,
                                        'answerWasVisible':True,'questionID':e['questionID'],'correct':True}
        report['recallSHA256']=sha(baseline)
        report['status']='PASS_REAL_UI_SYNTHETIC_NOT_DEVICE'
    except Exception as e:
        report['error']=type(e).__name__+': '+str(e)
        raise
    finally:
        try: sim('shutdown',device)
        except subprocess.CalledProcessError: pass
        try: sim('delete',device)
        finally: (OUT/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__': main()
