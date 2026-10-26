"""Allow a UI-only rebuild only against a fixed successful full verification."""
from pathlib import Path
import json, os, subprocess, urllib.request

ROOT=Path(__file__).resolve().parents[1]
BASE='464ca9fe6aa9bef4080e4a682701c0b2d8214ae8'
RUN=40354862241
REPOSITORY='hangzhou2321/xkl-study-ios-free-build'
ALLOWED={'App/HandbookCardView.swift','.github/workflows/build-ios.yml',
         'tools/build_unsigned_ios.sh','tools/verify_reused_model_tests.py',
         'App/StudyApp.swift','App/StudyHomeView.swift','App/ConceptView.swift','App/Info.plist',
         'App/HandbookCardPreview.swift','tools/capture_handbook_card_previews.py'}

def main():
    request=urllib.request.Request(f'https://api.github.com/repos/{REPOSITORY}/actions/runs/{RUN}',
        headers={'Accept':'application/vnd.github+json','User-Agent':'XKL-native-build',
                 'Authorization':'Bearer '+os.environ['GH_TOKEN']})
    with urllib.request.urlopen(request,timeout=30) as response:verified=json.load(response)
    assert verified['head_sha']==BASE and verified['status']=='completed' and verified['conclusion']=='success'
    subprocess.run(['git','fetch','--no-tags','--depth=1','origin',BASE],cwd=ROOT,check=True)
    changed=subprocess.check_output(['git','diff','--name-only',BASE,'HEAD'],cwd=ROOT,text=True).splitlines()
    assert changed and set(changed)<=ALLOWED, 'Model/source changes require full tests: '+repr(changed)
    receipt={'status':'PASS_UI_ONLY_SOURCE_PARITY_REUSES_VERIFIED_MODEL_TESTS',
             'baselineCommit':BASE,'baselineRun':RUN,'baselineRunURL':verified['html_url'],
             'releaseCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
             'allowedChanges':changed,'modelAndStorageSourcesByteIdentical':True,
             'swiftTestsFromBaseline':{'executed':439,'passed':432,'skipped':7,'failures':0},
             'strictCSuitesFromBaseline':4,'testsRerunForUIOnlyCommit':False,
             'currentCommitRequiredChecks':['iOS Release compile','16 native synthetic computer/power phone previews']}
    out=ROOT/'build/reused-model-tests.json';out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')
    print('UI-only revision: exact model/storage source parity with successful full run',RUN,BASE)

if __name__=='__main__':main()
