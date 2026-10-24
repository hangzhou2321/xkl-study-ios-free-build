#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "An Apple macOS/Xcode build host is required. This script does not install or purchase one." >&2
  exit 2
fi
python3 tools/generate_xcode_project.py --without-personal-resources
swift test --jobs 2
xcodebuild -project XKLStudy.xcodeproj -scheme XKLStudy -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
python3 - <<'PY'
from pathlib import Path
import zipfile
app = Path('build/DerivedData/Build/Products/Release-iphoneos/XKLStudy.app')
assert app.is_dir()
with zipfile.ZipFile('build/XKLStudy-unsigned.ipa', 'w', zipfile.ZIP_DEFLATED) as archive:
    for item in sorted(app.rglob('*')):
        if item.is_file():
            archive.write(item, str(Path('Payload/XKLStudy.app') / item.relative_to(app)))
print('Built build/XKLStudy-unsigned.ipa; this needs personal signing before installation.')
assert Path('build/XKLStudy-unsigned.ipa').stat().st_size <= 8 * 1024 * 1024, 'Unexpectedly large source-only app: stop before artifact upload'
PY
