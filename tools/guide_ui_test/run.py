#!/usr/bin/env python3
"""Real screen-coordinate XCTest on the unmodified production root, synthetic simulator only."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from capture_professional_question_previews import select_device, simulator_webkit_workaround, sim

OUT = ROOT / 'build' / 'professional-touch-uitest'
BUNDLE = 'local.xkl.study'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_logged(cmd, path, env, timeout):
    with path.open('w', encoding='utf8') as log:
        process = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, text=True, env=env, timeout=timeout)
    if process.returncode:
        raise RuntimeError('Command failed; inspect ' + path.name)


def seed(device, source, target, env):
    container = Path(sim('get_app_container', device, BUNDLE, 'data').strip()).resolve()
    capture = str(uuid.uuid4())
    command = ['xcrun', 'simctl', 'launch', '--terminate-running-process', device, BUNDLE,
               '--handbook-card-preview', '--case=paused-switch', '--subject=' + source, '--capture-id=' + capture]
    # This DEBUG helper only seeds synthetic files. The actual XCTest later
    # launches the unmodified ordinary RootView and taps real screen coordinates.
    subprocess.run(command, check=True, capture_output=True, text=True, env=env, timeout=180)
    deadline = time.monotonic() + 300
    root = None
    while time.monotonic() < deadline:
        candidates = list((container / 'tmp').glob('synthetic-handbook-' + source + '-*'))
        for candidate in candidates:
            a = candidate / 'HandbookWordRecall' / source / 'current.json'
            b = candidate / 'HandbookWordRecall' / target / 'current.json'
            f = candidate / 'StudyFlow' / 'current.json'
            try:
                flow = json.loads(f.read_text(encoding='utf8'))
                data = json.loads(a.read_text(encoding='utf8'))
                other = json.loads(b.read_text(encoding='utf8'))
                state = data['state']; word = state['word']; dual = state.get('dualFSRS')
                present = ((dual.get('shown') or {}).get('presentation') or {}) if dual else (word.get('presentation') or {})
                ratings = len(dual.get('events', [])) if dual else len(word.get('attempts', []))
                if (flow.get('isPaused') is True and flow.get('activeArea') == source
                        and flow.get('mode') == 'fiveMinutes' and flow.get('budgetSeconds') == 300
                        and flow.get('elapsedSeconds') == 40 and present.get('revealed') is True
                        and ratings == 1 and other.get('subject') == target):
                    root = candidate
                    break
            except (OSError, ValueError, KeyError, TypeError):
                pass
        if root is not None: break
        time.sleep(0.25)
    if root is None: raise RuntimeError('Synthetic paused source/target fixture did not become ready')
    try: sim('terminate', device, BUNDLE)
    except subprocess.CalledProcessError: pass
    support = container / 'Library' / 'Application Support'
    support.mkdir(parents=True, exist_ok=True)
    for folder in ('HandbookWordRecall', 'StudyFlow'):
        destination = support / folder
        if destination.exists(): raise RuntimeError('Fresh simulator unexpectedly contains existing ' + folder)
        shutil.copytree(root / folder, destination)
    source_file = support / 'HandbookWordRecall' / source / 'current.json'
    target_file = support / 'HandbookWordRecall' / target / 'current.json'
    flow_file = support / 'StudyFlow' / 'current.json'
    baseline = {'source': json.loads(source_file.read_text(encoding='utf8')),
                'target': json.loads(target_file.read_text(encoding='utf8')),
                'flow': json.loads(flow_file.read_text(encoding='utf8')),
                'sourceSHA256': sha(source_file), 'targetSHA256': sha(target_file)}
    return container, baseline


def check_records(container, source, target, baseline):
    support = container / 'Library' / 'Application Support'
    source_file = support / 'HandbookWordRecall' / source / 'current.json'
    target_file = support / 'HandbookWordRecall' / target / 'current.json'
    flow_file = support / 'StudyFlow' / 'current.json'
    current = json.loads(source_file.read_text(encoding='utf8'))
    target_current = json.loads(target_file.read_text(encoding='utf8'))
    flow = json.loads(flow_file.read_text(encoding='utf8'))
    before_word = baseline['source']['state']['word']
    after_word = current['state']['word']
    before_dual = baseline['source']['state'].get('dualFSRS')
    after_dual = current['state'].get('dualFSRS')
    if (current['state']['originalCardIDs'] != baseline['source']['state']['originalCardIDs']
            or after_word.get('attempts') != before_word.get('attempts')
            or after_word.get('presentation') != before_word.get('presentation')
            or current['state'].get('frozenToken') != baseline['source']['state'].get('frozenToken')
            or ((before_dual or {}).get('events') != (after_dual or {}).get('events'))
            or ((before_dual or {}).get('shown') != (after_dual or {}).get('shown'))):
        raise RuntimeError('Synthetic source rating, IDs or frozen presentation changed')
    if target_current != baseline['target'] or sha(target_file) != baseline['targetSHA256']:
        raise RuntimeError('Synthetic destination record changed while merely switching')
    if (flow.get('isPaused') is not True or flow.get('activeArea') != source
            or flow.get('mode') != 'fiveMinutes' or flow.get('budgetSeconds') != 300
            or flow.get('segmentID') != baseline['flow'].get('segmentID')
            or not isinstance(flow.get('elapsedSeconds'), (int, float)) or flow['elapsedSeconds'] < 40):
        raise RuntimeError('Synthetic five-minute paused segment did not survive the switch')
    return {'sourceCardIDsAttemptsPresentationUnchanged': True, 'targetFileByteUnchanged': True,
            'sourceBaselineSHA256': baseline['sourceSHA256'], 'sourceAfterSHA256': sha(source_file),
            'targetSHA256': sha(target_file), 'flowPaused': True, 'budgetSeconds': 300,
            'elapsedSeconds': flow['elapsedSeconds'], 'segmentIDUnchanged': True}


def main():
    if platform.system() != 'Darwin': raise SystemExit('Requires macOS and iOS Simulator')
    source = os.environ.get('TOUCH_TEST_SOURCE', 'power')
    if source not in ('power', 'mechanics'): raise ValueError('invalid synthetic source')
    target = 'mechanics' if source == 'power' else 'power'
    os.chdir(ROOT); OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, info = select_device()
    if name != 'iPhone SE (3rd generation)': raise RuntimeError('Compact iPhone SE 3 unavailable')
    launch_env, workaround = simulator_webkit_workaround(info)
    env = dict(os.environ)
    env['GUIDE_TEST_DYLD_FALLBACK'] = launch_env.get('SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH', '')
    template_path = ROOT / 'tools/guide_ui_test/GuideDisclosureUITests.swift'
    template = template_path.read_text(encoding='utf8')
    marker = '"__GUIDE_TEST_FALLBACK_PLACEHOLDER__"'
    if template.count(marker) != 1: raise RuntimeError('Fallback placeholder missing or ambiguous')
    template_path.write_text(template.replace(marker, json.dumps(env['GUIDE_TEST_DYLD_FALLBACK'])), encoding='utf8')
    subprocess.run(['python3', 'tools/guide_ui_test/generate_project.py', '--without-personal-resources'], check=True, env=env)
    device = sim('create', 'ProfessionalTouch-' + uuid.uuid4().hex[:12], kind, runtime).strip()
    report = {'status': 'INCOMPLETE', 'syntheticOnly': True, 'physicalDeviceTested': False,
              'source': source, 'target': target, 'device': name, 'runtime': info.get('version'), 'cases': {},
              'simulatorWorkaround': workaround, 'productionRootUnmodified': True,
              'selectionMethod': 'XCUITest coordinate tap and drag on actual segmented control',
              'limitations': ['Destination synthetic card package has no existing presentation.',
                              'Simulator test does not demonstrate physical iPhone behavior.']}
    try:
        sim('boot', device); sim('bootstatus', device, '-b')
        subprocess.run(['open', '-a', 'Simulator', '--args', '-CurrentDeviceUDID', device], check=True)
        base = ['xcodebuild', '-project', 'XKLStudy.xcodeproj', '-scheme', 'XKLStudy', '-configuration', 'Debug',
                '-destination', 'platform=iOS Simulator,id=' + device, '-derivedDataPath', str(OUT / 'DerivedData'),
                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
                'ARCHS=' + platform.machine(), 'ONLY_ACTIVE_ARCH=YES']
        run_logged(base + ['build-for-testing'], OUT / 'build.log', env, 1200)
        app = OUT / 'DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app'
        if not app.is_dir(): raise RuntimeError('Simulator app not built')
        for gesture in ('tap', 'drag'):
            case_dir = OUT / gesture; case_dir.mkdir(exist_ok=True)
            result = case_dir / 'ProfessionalTouch.xcresult'
            case_report = {'status': 'INCOMPLETE', 'gesture': gesture}
            report['cases'][gesture] = case_report
            try:
                sim('install', device, str(app))
                container, baseline = seed(device, source, target, {**env, **launch_env})
                case = ('testPowerToMechanics' if source == 'power' else 'testMechanicsToPower') + gesture.capitalize()
                run_logged(base + ['test-without-building', '-resultBundlePath', str(result), '-parallel-testing-enabled', 'NO',
                                   '-only-testing:GuideDisclosureUITests/GuideDisclosureUITests/' + case,
                                   '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                                   '-maximum-test-execution-time-allowance', '240'], case_dir / 'xcodebuild-test.log', env, 1200)
                actual_container = Path(sim('get_app_container', device, BUNDLE, 'data').strip()).resolve()
                # XCTest may reinstall the app into a different simulator path.
                # Verify the actual live container's records against the seed.
                case_report['simulatorContainerRelocated'] = actual_container != container
                case_report['records'] = check_records(actual_container, source, target, baseline)
                case_report['status'] = 'PASS'
            except Exception as error:
                case_report['failure'] = type(error).__name__ + ': ' + str(error)
                case_report['status'] = 'FAIL_OR_INCOMPLETE'
            finally:
                if result.exists():
                    attachments = case_dir / 'attachments'; attachments.mkdir(exist_ok=True)
                    export = subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result),
                                             '--output-path', str(attachments)], capture_output=True, text=True)
                    case_report['attachmentExportExitCode'] = export.returncode
                    if export.returncode: case_report['status'] = 'INCOMPLETE_ATTACHMENT_EXPORT_FAILED'
                try: sim('terminate', device, BUNDLE)
                except subprocess.CalledProcessError: pass
                # This UDID was just created by this script and contains synthetic data only.
                try: sim('uninstall', device, BUNDLE)
                except subprocess.CalledProcessError: pass
                (case_dir / 'summary.json').write_text(json.dumps(case_report, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
                print('SYNTHETIC_TOUCH_CASE', gesture, case_report['status'], flush=True)
        if not all(case.get('status') == 'PASS' for case in report['cases'].values()):
            raise RuntimeError('At least one real-coordinate case failed or was incomplete')
        report['status'] = 'PASS_PRODUCTION_ROOT_REAL_COORDINATE_TAP_AND_DRAG'
    except Exception as error:
        report['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        try: sim('shutdown', device)
        except subprocess.CalledProcessError: pass
        try: sim('delete', device)
        finally: (OUT / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
