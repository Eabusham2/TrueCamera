#!/usr/bin/env python3
"""Use a stable installed Xcode, preferring the current iOS 27 SDK."""
from pathlib import Path
import os, re, subprocess
candidates = []
for app in Path('/Applications').glob('Xcode*.app'):
    if any(x in (app.name + ' ' + app.resolve().name).lower() for x in ('beta', 'candidate', '_rc')):
        continue
    developer = app / 'Contents/Developer'
    try:
        result = subprocess.check_output([str(developer/'usr/bin/xcodebuild'), '-version'], text=True,
                                         env={**os.environ, 'DEVELOPER_DIR': str(developer)})
        match = re.search(r'Xcode\s+([0-9.]+)', result)
        if match:
            version = tuple(int(x) for x in match.group(1).split('.'))
            candidates.append((version, str(developer)))
    except (OSError, subprocess.CalledProcessError):
        continue
if not candidates:
    raise SystemExit('No stable Xcode installation was found; refusing to silently select a beta toolchain.')
version, developer = max(candidates)
if version[0] < 27:
    raise SystemExit('This release requires Xcode 27+ so hardware aperture APIs are compiled.')
subprocess.run(['sudo', 'xcode-select', '--switch', developer], check=True)
print('Selected stable Xcode', '.'.join(map(str, version)), developer)
