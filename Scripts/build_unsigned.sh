#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/release
python3 Scripts/generate_project.py
rm -rf build/Build.xcresult
xcodebuild -project TrueCamera.xcodeproj -scheme TrueCamera \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData -resultBundlePath build/Build.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build 2>&1 | tee build/logs/device-build.log
APP='build/DerivedData/Build/Products/Release-iphoneos/TrueCamera.app'
test -d "$APP"
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/TrueCamera.app
PACKED='build/package/Payload/TrueCamera.app'
rm -rf "$PACKED/_CodeSignature" "$PACKED/embedded.mobileprovision"
if codesign -d "$PACKED/TrueCamera" >/dev/null 2>&1; then codesign --remove-signature "$PACKED/TrueCamera"; fi
if codesign -d "$PACKED/TrueCamera" >/dev/null 2>&1; then echo 'ERROR: executable remains signed' >&2; exit 1; fi
rm -f build/release/TrueCamera-unsigned.ipa
(cd build/package && zip -qry ../release/TrueCamera-unsigned.ipa Payload)
python3 Scripts/verify_ipa.py build/release/TrueCamera-unsigned.ipa
(cd build/release && shasum -a 256 TrueCamera-unsigned.ipa > TrueCamera-unsigned.ipa.sha256)
python3 - <<'PY'
import json,os,subprocess
from pathlib import Path
commit=os.getenv('GITHUB_SHA')
if not commit:
    try:commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True,stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:commit='unversioned source'
info={'commit':commit,'run':os.getenv('GITHUB_RUN_ID'),'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
      'app':'TrueCamera','sdk':subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip(),'physical_aperture_api_compiled':int(subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).split('.')[0]) >= 27,'signed':False,'minimum_iOS':'17.0','hardware_validation':'Not certified by CI'}
Path('build/release/build-info.json').write_text(json.dumps(info,indent=2)+'\n')
PY
printf '\nUnsigned IPA: %s\n' "$PWD/build/release/TrueCamera-unsigned.ipa"
