#!/usr/bin/env python3
"""Run real simulator taps against an isolated, six-row synthetic card."""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from capture_professional_question_previews import select_device, simulator_webkit_workaround, sim

OUT = ROOT / 'build' / 'guide-ui-test'
BUNDLE = 'local.xkl.study'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def snapshot(root):
    return {p.relative_to(root).as_posix(): digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

def monitor(device, stop, state):
    container = None
    while not stop.is_set():
        try:
            if container is None:
                result = subprocess.run(['xcrun','simctl','get_app_container',device,BUNDLE,'data'], capture_output=True, text=True)
                if result.returncode == 0: container = Path(result.stdout.strip())
            if container is not None:
                for current in (container/'tmp').glob('synthetic-handbook-*/HandbookWordRecall/*/current.json'):
                    value = json.loads(current.read_text(encoding='utf8'))
                    word = value.get('state', {}).get('word', {})
                    pkg = value.get('state', {}).get('package', {})
                    present = word.get('presentation') or {}
                    if pkg.get('id') != 'synthetic-handbook-package' or present.get('revealed') is not True or word.get('attempts') != []:
                        continue
                    subject = value.get('subject')
                    if subject not in ('computer','power'): continue
                    files = snapshot(current.parent)
                    found = state.setdefault(subject, {'baseline': files, 'samples': 0, 'changes': []})
                    found['samples'] += 1
                    if files != found['baseline']:
                        found['changes'].append({'expected': found['baseline'], 'actual': files})
        except (OSError, ValueError) as exc:
            state.setdefault('transientReadErrors', []).append(type(exc).__name__)
        stop.wait(0.15)

def main():
    if platform.system() != 'Darwin': raise SystemExit('Requires macOS with Xcode and iOS Simulator')
    os.chdir(ROOT); OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, info = select_device()
    if name != 'iPhone SE (3rd generation)': raise RuntimeError('Compact iPhone SE 3 simulator unavailable; do not substitute silently')
    env, workaround = simulator_webkit_workaround(info)
    test_env = dict(os.environ)
    test_env['GUIDE_TEST_DYLD_FALLBACK'] = env.get('SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH', '')
    # Xcode does not reliably forward host variables into the XCUITest runner.
    # Bind the verified simulator-runtime path directly into the synthetic test
    # source in this disposable CI checkout; production App sources are untouched.
    test_source = ROOT/'tools'/'guide_ui_test'/'GuideDisclosureUITests.swift'
    template = test_source.read_text(encoding='utf8')
    marker = '"__GUIDE_TEST_FALLBACK_PLACEHOLDER__"'
    if template.count(marker) != 1:
        raise RuntimeError('Synthetic test fallback placeholder missing or ambiguous')
    bound = template.replace(marker, json.dumps(test_env['GUIDE_TEST_DYLD_FALLBACK']))
    test_source.write_text(bound, encoding='utf8')
    (OUT/'generated-test-source.swift').write_text(bound, encoding='utf8')
    subprocess.run(['python3', 'tools/guide_ui_test/generate_project.py', '--without-personal-resources'], check=True, env=test_env)
    device = sim('create', 'GuideUITest-' + uuid.uuid4().hex[:12], kind, runtime).strip()
    state, stop = {}, threading.Event()
    started_at = time.time()
    observer = None
    result_path = OUT/'GuideDisclosure.xcresult'
    report = {'status':'INCOMPLETE','device':name,'runtime':info.get('version'),'syntheticOnly':True,'physicalDeviceTested':False,'webkitWorkaround':workaround}
    try:
        sim('boot',device); sim('bootstatus',device,'-b')
        subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',device],check=True)
        observer = threading.Thread(target=monitor,args=(device,stop,state),daemon=True);observer.start()
        cmd = ['xcodebuild','test','-project','XKLStudy.xcodeproj','-scheme','XKLStudy','-configuration','Debug',
               '-destination','platform=iOS Simulator,id='+device,'-derivedDataPath',str(OUT/'DerivedData'),
               '-resultBundlePath',str(result_path),'-parallel-testing-enabled','NO','-only-testing:GuideDisclosureUITests',
               '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','120',
               '-maximum-test-execution-time-allowance','180',
               'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=',
               'ARCHS='+platform.machine(),'ONLY_ACTIVE_ARCH=YES']
        with (OUT/'xcodebuild.log').open('w',encoding='utf8') as stream:
            try:
                process = subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,text=True,env=test_env,timeout=1200)
                report['xcodebuildExitCode'] = process.returncode
            except subprocess.TimeoutExpired:
                report['xcodebuildExitCode'] = 124
                report['timeout'] = 'xcodebuild exceeded 1200 seconds; test outcome remains unverified'
        if result_path.exists():
            attachments = OUT/'attachments';attachments.mkdir(exist_ok=True)
            exported = subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result_path),'--output-path',str(attachments)],capture_output=True,text=True)
            report['attachmentExportExitCode'] = exported.returncode
            (OUT/'attachment-export.log').write_text(exported.stdout+'\n'+exported.stderr,encoding='utf8')
    finally:
        stop.set()
        if observer is not None: observer.join(timeout=10)
        report['recordObservation'] = state
        report['finishedAtUTC'] = time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        # The runner is ephemeral and only our synthetic app is built here. Retain
        # fresh named app crashes when available; no other process reports are read.
        diagnostic_dir = Path.home()/'Library'/'Logs'/'DiagnosticReports'
        crashes = []
        if diagnostic_dir.is_dir():
            for p in diagnostic_dir.glob('XKLStudy-*.ips'):
                if p.is_file() and not p.is_symlink() and p.stat().st_mtime >= started_at and p.stat().st_size <= 5*1024*1024:
                    dest = OUT/('synthetic-crash-'+p.name)
                    shutil.copy2(p,dest)
                    crashes.append({'name':dest.name,'sha256':digest(dest)})
        report['freshSyntheticAppCrashReports'] = crashes
        try: sim('shutdown',device)
        except subprocess.CalledProcessError: pass
        sim('delete',device)
        (OUT/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    if report.get('xcodebuildExitCode') != 0:
        raise RuntimeError('XCUITest failed; inspect xcodebuild.log and xcresult')
    for subject in ('computer','power'):
        result=state.get(subject,{})
        if result.get('samples',0)<10 or result.get('changes'):
            raise RuntimeError('Synthetic post-reveal record evidence incomplete or changed: '+subject)
    if report.get('attachmentExportExitCode') != 0:
        raise RuntimeError('Screenshot attachments could not be exported')
    report['status']='PASS_REAL_SIMULATOR_TAPS_AND_SYNTHETIC_RECORD_HASH_MONITOR'
    report['limitations']=['Synthetic six-row fixture only; no private package or physical iPhone.',
                           'Host sampled synthetic file hashes after reveal; transient writes between samples are not excluded.',
                           'Does not establish VoiceOver or larger Dynamic Type accessibility.']
    (OUT/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__ == '__main__': main()
