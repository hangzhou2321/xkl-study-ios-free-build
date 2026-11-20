#!/bin/bash
set -euo pipefail
test "$(git hash-object App/OriginalPracticeView.swift)" = "$(git rev-parse 8f2fdc6:App/OriginalPracticeView.swift)"
test "$(git hash-object App/OriginalPracticeStorage.swift)" = "$(git rev-parse 8f2fdc6:App/OriginalPracticeStorage.swift)"
mkdir -p logs
xcodebuild -version
xcrun simctl list -j devices available > logs/devices.json
UDID=$(python3 - <<'PY'
import json
j=json.load(open("logs/devices.json"))['devices']
rs=sorted((k for k in j if 'iOS-' in k),key=lambda k:tuple(map(int,k.split('iOS-')[-1].split('-'))),reverse=True)
for runtime in rs:
    iphones=[v for v in j[runtime] if v['name'].startswith('iPhone')]
    if iphones:print(iphones[0]['udid']); break
else:raise RuntimeError('No available iPhone')
PY
)
xcrun simctl boot "$UDID" || true
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
vers=$(xcrun --sdk iphonesimulator --show-sdk-version)
app="$RUNNER_TEMP/MiniWK.app"; mkdir -p "$app/OriginalPractice"
cp mini-wk-probe/OriginalPractice/*.html "$app/OriginalPractice/"
python3 - "$app/Info.plist" "$vers" <<'PY'
import plistlib,sys
p=dict(CFBundleIdentifier='test.synthetic.originalwk',CFBundleName='MiniWK',CFBundleExecutable='MiniWK',CFBundlePackageType='APPL',CFBundleShortVersionString='1.0',CFBundleVersion='1',CFBundleDevelopmentRegion='en',CFBundleSupportedPlatforms=['iPhoneSimulator'],DTPlatformName='iphonesimulator',DTSDKName='iphonesimulator'+sys.argv[2],MinimumOSVersion='17.0',UIDeviceFamily=[1,2],UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'],LSRequiresIPhoneOS=True)
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$sdk" -module-name MiniWK mini-wk-probe/Probe.swift App/OriginalPractice{View,Storage}.swift -o "$app/MiniWK" 2>&1 | tee logs/compile.log
codesign --force --sign - "$app"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$app"
xcrun simctl launch "$UDID" test.synthetic.originalwk
data=$(xcrun simctl get_app_container "$UDID" test.synthetic.originalwk data)
log="$data/Documents/wk-telemetry.jsonl"; export SYNTH_LOG="$log"
capture() {
    [ -f "$log" ] && cp "$log" logs/wk-telemetry.jsonl || true
    [ -f "$data/Library/Application Support/OriginalPracticeProgress/original-practice-v1.json" ] && cp "$data/Library/Application Support/OriginalPracticeProgress/original-practice-v1.json" logs/synthetic-store.json || true
}
for i in {1..18}; do sleep 4;capture; grep -q '"t":50' "$log" 2>/dev/null && break || true;done
if [ -f logs/wk-telemetry.jsonl ];then cat logs/wk-telemetry.jsonl; fi
xcrun simctl io "$UDID" screenshot logs/first.png || true
xcrun simctl terminate "$UDID" test.synthetic.originalwk || true
xcrun simctl launch "$UDID" test.synthetic.originalwk
sleep 24; capture
xcrun simctl io "$UDID" screenshot logs/relaunch.png || true
python3 - <<'PY'
import json,os
rows=[json.loads(s) for s in open(os.environ['SYNTH_LOG'])]
runs=list(dict.fromkeys(r['run'] for r in rows))
print('launches',runs)
assert len(runs)==2
for i,u in enumerate(runs):
 own=[r for r in rows if r['run']==u]; ev=[json.loads(r['eval']) for r in own if 'eval'in r and r['eval']!='(nil)']; print(i,[(x['title'], x['ready'],x['bridge'], x.get('stored')) for x in ev])
 assert any(x['title']=='SYNTH-HOME' and x['bridge'] for x in ev)
 assert any(x['title']=='SYNTH-QUESTION' and x['bridge'] for x in ev)
 assert any(r.get('action')=='answer' and r.get('feedback')=='one' for r in own)
 if i==1:assert next(x for x in ev if x['title']=='SYNTH-HOME')['stored']=='one'
assert json.load(open('logs/synthetic-store.json'))['entries']['real-bank-offline-v1:item/synthetic-probe']=='one'
PY
